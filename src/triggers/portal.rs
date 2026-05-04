//! GlobalShortcuts portal backend (KDE 6, GNOME 46+). Async-only and
//! batch-binds, so it sits outside the trait-based IPC backends.

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

/// Bounded timeout so a wedged D-Bus doesn't stall daemon startup.
pub async fn is_available() -> bool {
    matches!(
        tokio::time::timeout(Duration::from_secs(2), GlobalShortcuts::new()).await,
        Ok(Ok(_))
    )
}

/// Returns when SIGINT or the activation stream ends.
pub async fn run(bindings: Vec<Binding>) -> Result<RunSummary> {
    let proxy = GlobalShortcuts::new()
        .await
        .context("create GlobalShortcuts proxy")?;

    let session = proxy
        .create_session(CreateSessionOptions::default())
        .await
        .context("create GlobalShortcuts session")?;

    // `wflow.` prefix so the portal config UI clearly attributes them.
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
                // trigger-fire gates on the workflow's `when`. KDE 6 /
                // GNOME 46+ have no class/title probe; falls open there.
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

/// `super+alt+d` → `LOGO+ALT+d`. Modifier names per the portal spec:
/// CTRL, SHIFT, ALT, LOGO. Leaf key passes through verbatim.
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
