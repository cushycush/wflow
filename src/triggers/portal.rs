//! GlobalShortcuts portal backend (KDE Plasma 6, GNOME 46+).
//!
//! Doesn't fit the sync `Backend` trait the IPC backends share —
//! the portal is async-only, batch-binds shortcuts in one call, and
//! delivers activations as a D-Bus signal stream. So this module
//! exposes its own entry point and `cmd_daemon` picks it up before
//! the trait-based fallback.
//!
//! Flow:
//!
//! 1. `GlobalShortcuts::new()` — creates the proxy, fails fast when
//!    the portal interface isn't reachable. Used as the availability
//!    probe.
//! 2. `create_session(...)` — opens a session. The portal binds the
//!    shortcuts to that session; when the daemon exits and the
//!    session drops, the portal unbinds for us.
//! 3. `bind_shortcuts(...)` — one batch call with every chord. KDE
//!    and GNOME both pop a consent dialog the first time so the user
//!    sees what we're asking for.
//! 4. `receive_activated()` — Stream of `Activated` events. Per fire
//!    we spawn a `wflow run <id> --yes` subprocess, same pattern the
//!    Hyprland and Sway backends use.
//!
//! The daemon stays alive until SIGINT. When it exits, the portal
//! cleans the bound shortcuts up automatically.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use ashpd::desktop::global_shortcuts::{BindShortcutsOptions, GlobalShortcuts, NewShortcut};
use ashpd::desktop::CreateSessionOptions;
use futures_util::StreamExt;
use tokio::process::Command;

use crate::actions::TriggerKind;

use super::Binding;

/// True when the GlobalShortcuts portal is reachable. Bounded to a
/// short timeout so a busy or broken D-Bus doesn't stall daemon
/// startup. Async because ashpd is async-only.
pub async fn is_available() -> bool {
    matches!(
        tokio::time::timeout(Duration::from_secs(2), GlobalShortcuts::new()).await,
        Ok(Ok(_))
    )
}

/// Run the daemon in portal mode. Binds every chord trigger via the
/// portal, dispatches `wflow run <id> --yes` per activation, returns
/// when SIGINT or the activation stream ends.
pub async fn run(bindings: Vec<Binding>) -> Result<RunSummary> {
    let proxy = GlobalShortcuts::new()
        .await
        .context("create GlobalShortcuts proxy")?;

    let session = proxy
        .create_session(CreateSessionOptions::default())
        .await
        .context("create GlobalShortcuts session")?;

    // Build the batch and a reverse lookup from portal-shortcut-id to
    // workflow-id. We namespace shortcut ids with `wflow.` so the
    // portal config UI shows them clearly even alongside other apps.
    let mut shortcuts: Vec<NewShortcut> = Vec::new();
    let mut id_to_workflow: HashMap<String, String> = HashMap::new();
    let mut skipped_non_chord = 0usize;
    for b in &bindings {
        let chord = match &b.trigger.kind {
            TriggerKind::Chord { chord } => chord,
            _ => {
                skipped_non_chord += 1;
                continue;
            }
        };
        let portal_chord = translate_chord(chord)?;
        let shortcut_id = format!("wflow.{}", b.workflow_id);
        let s = NewShortcut::new(shortcut_id.clone(), b.workflow_title.clone())
            .preferred_trigger(Some(portal_chord.as_str()));
        shortcuts.push(s);
        id_to_workflow.insert(shortcut_id, b.workflow_id.clone());
    }

    if shortcuts.is_empty() {
        return Ok(RunSummary {
            registered: 0,
            skipped_non_chord,
        });
    }

    proxy
        .bind_shortcuts(
            &session,
            &shortcuts,
            None,
            BindShortcutsOptions::default(),
        )
        .await
        .context("portal BindShortcuts (user may have declined consent)")?;

    let mut activated = proxy
        .receive_activated()
        .await
        .context("subscribe to portal Activated stream")?;

    let wflow_bin: PathBuf = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("wflow"));

    let term = tokio::signal::ctrl_c();
    tokio::pin!(term);

    let registered = shortcuts.len();
    loop {
        tokio::select! {
            _ = &mut term => {
                tracing::info!("portal daemon: SIGINT received, exiting");
                break;
            }
            ev = activated.next() => {
                let Some(ev) = ev else {
                    tracing::warn!("portal Activated stream ended; exiting");
                    break;
                };
                let id = ev.shortcut_id();
                let Some(workflow_id) = id_to_workflow.get(id).cloned() else {
                    tracing::warn!(id, "portal: activated unknown shortcut id");
                    continue;
                };
                let bin = wflow_bin.clone();
                // Dispatch via `trigger-fire` so the workflow's
                // `trigger.when` predicate gets checked against the
                // focused window before the engine runs. KDE Plasma 6
                // and GNOME 46+ don't expose a class/title probe yet;
                // the wrapper falls open in that case so the chord
                // still fires.
                tokio::spawn(async move {
                    let status = Command::new(&bin)
                        .args(["trigger-fire", &workflow_id])
                        .status()
                        .await;
                    match status {
                        Ok(s) if s.success() => {}
                        Ok(s) => tracing::warn!(workflow_id, ?s, "trigger-fire exited non-zero"),
                        Err(e) => tracing::warn!(workflow_id, ?e, "trigger-fire failed to spawn"),
                    }
                });
            }
        }
    }

    drop(session);
    Ok(RunSummary {
        registered,
        skipped_non_chord,
    })
}

pub struct RunSummary {
    pub registered: usize,
    pub skipped_non_chord: usize,
}

/// Translate wflow chord syntax (`super+alt+d`) into the portal's
/// preferred-trigger format (`LOGO+ALT+d`). Modifier names per
/// xdg-desktop-portal's GlobalShortcuts spec: CTRL, SHIFT, ALT, LOGO.
/// The leaf key passes through verbatim so XKB keysyms (Return, F1,
/// Page_Up) round-trip.
fn translate_chord(chord: &str) -> Result<String> {
    let parts: Vec<&str> = chord.split('+').map(str::trim).filter(|s| !s.is_empty()).collect();
    if parts.is_empty() {
        return Err(anyhow!("empty chord"));
    }
    let (key, mods) = parts.split_last().unwrap();
    let mod_strs: Vec<&'static str> = mods
        .iter()
        .map(|m| match m.to_ascii_lowercase().as_str() {
            "super" | "win" | "windows" | "logo" | "mod4" => Ok("LOGO"),
            "ctrl" | "control" => Ok("CTRL"),
            "alt" | "meta" | "mod1" => Ok("ALT"),
            "shift" => Ok("SHIFT"),
            other => Err(anyhow!("unknown modifier {other:?} in chord {chord:?}")),
        })
        .collect::<Result<Vec<_>>>()?;
    let mut out = mod_strs.join("+");
    if !out.is_empty() {
        out.push('+');
    }
    out.push_str(key);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn translates_simple_chord() {
        assert_eq!(translate_chord("super+alt+d").unwrap(), "LOGO+ALT+d");
    }

    #[test]
    fn translates_ctrl_shift_letter() {
        assert_eq!(translate_chord("ctrl+shift+u").unwrap(), "CTRL+SHIFT+u");
    }

    #[test]
    fn passes_through_named_keys() {
        assert_eq!(translate_chord("ctrl+Return").unwrap(), "CTRL+Return");
    }

    #[test]
    fn unknown_modifier_errors() {
        assert!(translate_chord("hyper+a").is_err());
    }
}
