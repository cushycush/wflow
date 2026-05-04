//! Hyprland trigger backend.
//!
//! Hyprland speaks two Unix sockets per session under
//! `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/`:
//!
//! - `.socket.sock` — synchronous request / response (what we use).
//! - `.socket2.sock` — async event stream (the recorder uses this).
//!
//! For trigger registration we send `keyword bind = MODS, KEY,
//! exec, wflow run <id> --yes` to `.socket.sock`. Hyprland holds
//! the binding for the lifetime of the compositor session;
//! `keyword unbind = MODS, KEY` removes it. The daemon stays alive
//! between bind and unbind so a Ctrl+C or graceful shutdown gets
//! to clean up.
//!
//! When the user fires the chord, Hyprland forks `wflow run <id>
//! --yes` as the dispatcher. The daemon doesn't see the fire — the
//! workflow runs in its own process. Trade-off: ~50ms fork latency
//! per fire, but the daemon stays trivial. v0.5 can swap in an IPC
//! callback path if perf matters.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

use anyhow::{anyhow, Context, Result};

use crate::actions::TriggerKind;

use super::{Backend, Binding};

pub struct HyprlandBackend {
    socket: PathBuf,
    /// Path to the wflow binary that this daemon process is running
    /// from. Captured once at construction so `keyword bind`
    /// dispatchers point at the right binary even if the user has
    /// multiple wflow installs on PATH.
    wflow_bin: PathBuf,
}

impl HyprlandBackend {
    pub fn new() -> Self {
        let socket = socket_path().expect(
            "HyprlandBackend constructed without HYPRLAND_INSTANCE_SIGNATURE — \
             check is_available() first",
        );
        let wflow_bin = std::env::current_exe()
            .unwrap_or_else(|_| PathBuf::from("wflow"));
        Self { socket, wflow_bin }
    }

    fn request(&self, line: &str) -> Result<String> {
        let mut stream = UnixStream::connect(&self.socket).with_context(|| {
            format!("connect Hyprland socket {}", self.socket.display())
        })?;
        stream
            .write_all(line.as_bytes())
            .context("write to Hyprland socket")?;
        stream
            .shutdown(std::net::Shutdown::Write)
            .context("close write half")?;
        let mut response = String::new();
        stream
            .read_to_string(&mut response)
            .context("read Hyprland response")?;
        Ok(response.trim().to_string())
    }
}

impl Backend for HyprlandBackend {
    fn name(&self) -> &'static str {
        "hyprland"
    }

    fn bind(&mut self, b: &Binding) -> Result<()> {
        let chord = match &b.trigger.kind {
            TriggerKind::Chord { chord } => chord,
            _ => return Err(anyhow!("hyprland backend: only chord triggers supported today")),
        };
        let (mods, key) = parse_chord(chord)?;

        // Evict any pre-existing bind for this chord first. Hyprland's
        // `keyword bind` ADDs a binding rather than replacing — without
        // this, a chord already bound in the user's hyprland.conf
        // (e.g. `bind = SUPER, T, exec, kitty`) and a wflow bind would
        // both fire on the chord. Pressing `Super+T` would launch kitty
        // AND fire the workflow, which is exactly the "wflow binds
        // should supersede all other binds" behaviour the user
        // flagged.
        //
        // Unbind silently — the response is "ok" on success or an
        // "Unable to find ..." style message otherwise. Either is
        // fine; the failure just means the chord wasn't bound to
        // anything yet. The user's hyprland.conf bind comes back on
        // a `hyprctl reload` after the daemon stops. A future polish
        // could remember + restore the previous bind on shutdown,
        // but the cost / complexity isn't worth it for v1.
        let unbind_cmd = format!("keyword unbind = {mods}, {key}");
        match self.request(&unbind_cmd) {
            Ok(resp) => tracing::debug!(chord, %resp, "pre-bind unbind"),
            Err(e) => tracing::debug!(chord, %e, "pre-bind unbind failed (chord likely not bound)"),
        }

        let cmd = format!(
            "keyword bind = {mods}, {key}, exec, {} run {} --yes",
            self.wflow_bin.display(),
            b.workflow_id,
        );
        let resp = self.request(&cmd)?;
        if resp != "ok" {
            return Err(anyhow!(
                "hyprland rejected bind for {chord:?}: {resp}"
            ));
        }
        Ok(())
    }

    fn unbind(&mut self, b: &Binding) -> Result<()> {
        let chord = match &b.trigger.kind {
            TriggerKind::Chord { chord } => chord,
            _ => return Ok(()),
        };
        let (mods, key) = parse_chord(chord)?;
        let cmd = format!("keyword unbind = {mods}, {key}");
        // Treat any non-ok response as a warning; we still want to
        // clean up other bindings on shutdown even if one fails.
        let resp = self.request(&cmd)?;
        if resp != "ok" {
            tracing::warn!(chord, response = %resp, "hyprland unbind returned non-ok");
        }
        Ok(())
    }
}

/// True when we can find a Hyprland session to talk to.
pub fn is_available() -> bool {
    socket_path().map(|p| p.exists()).unwrap_or(false)
}

fn socket_path() -> Option<PathBuf> {
    let his = std::env::var("HYPRLAND_INSTANCE_SIGNATURE").ok()?;
    let runtime = std::env::var("XDG_RUNTIME_DIR").ok()?;
    Some(
        PathBuf::from(runtime)
            .join("hypr")
            .join(&his)
            .join(".socket.sock"),
    )
}

/// Translate wflow's chord syntax (`super+alt+d`, `ctrl+shift+t`)
/// into Hyprland's bind syntax (mods joined with `&`, leaf key bare).
/// Modifiers Hyprland recognizes: `SUPER`, `CTRL`, `ALT`, `SHIFT`.
fn parse_chord(chord: &str) -> Result<(String, String)> {
    let parts: Vec<&str> = chord.split('+').map(str::trim).filter(|s| !s.is_empty()).collect();
    if parts.is_empty() {
        return Err(anyhow!("empty chord"));
    }
    let (key, mods) = parts.split_last().unwrap();
    let mod_strs: Vec<&'static str> = mods
        .iter()
        .map(|m| match m.to_ascii_lowercase().as_str() {
            "super" | "win" | "windows" | "logo" | "mod4" => Ok("SUPER"),
            "ctrl" | "control" => Ok("CTRL"),
            "alt" | "meta" | "mod1" => Ok("ALT"),
            "shift" => Ok("SHIFT"),
            other => Err(anyhow!("unknown modifier {other:?} in chord {chord:?}")),
        })
        .collect::<Result<Vec<_>>>()?;
    let mods_joined = mod_strs.join("&");
    // Hyprland is case-flexible on the leaf key. Pass it through
    // verbatim — wdotool keysyms like Return, Escape, Page_Up,
    // F1-F12 round-trip; lowercase letters / digits work as-is.
    Ok((mods_joined, key.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn translates_simple_chord() {
        let (m, k) = parse_chord("super+alt+d").unwrap();
        assert_eq!(m, "SUPER&ALT");
        assert_eq!(k, "d");
    }

    #[test]
    fn translates_ctrl_shift_letter() {
        let (m, k) = parse_chord("ctrl+shift+u").unwrap();
        assert_eq!(m, "CTRL&SHIFT");
        assert_eq!(k, "u");
    }

    #[test]
    fn passes_through_named_keys() {
        let (m, k) = parse_chord("ctrl+Return").unwrap();
        assert_eq!(m, "CTRL");
        assert_eq!(k, "Return");
    }

    #[test]
    fn unknown_modifier_errors() {
        let err = parse_chord("hyper+a").unwrap_err().to_string();
        assert!(err.contains("hyper"), "{err}");
    }
}
