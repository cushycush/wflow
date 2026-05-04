//! Hyprland IPC backend. Sends `keyword bind = MODS, KEY, exec,
//! wflow run <id> --yes` to `.socket.sock`. Hyprland forks the
//! dispatcher itself; the daemon never sees the fire.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

use anyhow::{anyhow, Context, Result};

use crate::actions::TriggerKind;

use super::{Backend, Binding};

pub struct HyprlandBackend {
    socket: PathBuf,
    /// Captured at construction so dispatchers stay pinned to this
    /// daemon's wflow binary even with multiple wflows on PATH.
    wflow_bin: PathBuf,
}

impl HyprlandBackend {
    pub fn new() -> Self {
        let socket = socket_path().expect(
            "HyprlandBackend constructed without HYPRLAND_INSTANCE_SIGNATURE, \
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

        // Evict pre-existing binds; `keyword bind` ADDs rather than
        // replacing. The user's hyprland.conf bind comes back on a
        // `hyprctl reload` after the daemon exits.
        let unbind_cmd = format!("keyword unbind = {mods}, {key}");
        match self.request(&unbind_cmd) {
            Ok(resp) => tracing::debug!(chord, %resp, "pre-bind unbind"),
            Err(e) => tracing::debug!(chord, %e, "pre-bind unbind failed (chord likely not bound)"),
        }

        // Dispatch via `trigger-fire` so the workflow's
        // `trigger.when` predicate gets checked against the focused
        // window before the engine runs. `wflow run` stays the
        // ungated public path for cron / scripts.
        let cmd = format!(
            "keyword bind = {mods}, {key}, exec, {} trigger-fire {}",
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
        let resp = self.request(&cmd)?;
        if resp != "ok" {
            tracing::warn!(chord, response = %resp, "hyprland unbind returned non-ok");
        }
        Ok(())
    }
}

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

/// `super+alt+d` → (`SUPER&ALT`, `d`). Hyprland modifier names:
/// `SUPER`, `CTRL`, `ALT`, `SHIFT`.
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
