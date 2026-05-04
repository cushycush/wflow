//! Sway trigger backend.
//!
//! Sway speaks i3's IPC protocol over the Unix socket exposed via
//! `$SWAYSOCK`. Frame layout per `sway-ipc(7)`:
//!
//! - 6 bytes: magic `i3-ipc`
//! - 4 bytes LE: payload length
//! - 4 bytes LE: payload type (0 = RUN_COMMAND)
//! - N bytes: payload
//!
//! The response uses the same header shape; we read it back to
//! confirm `success: true` came through. We avoid shelling out to
//! `swaymsg` so a missing CLI doesn't trip the daemon — the socket
//! is what's actually authoritative.
//!
//! Bind: `bindsym MODS+KEY exec wflow run <id> --yes`. Sway holds
//! the binding for the lifetime of the compositor session, just
//! like Hyprland does. Unbind: `unbindsym MODS+KEY`. The daemon
//! cleans up on Ctrl+C.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

use anyhow::{anyhow, Context, Result};

use crate::actions::TriggerKind;

use super::{Backend, Binding};

const MAGIC: &[u8; 6] = b"i3-ipc";
const TYPE_RUN_COMMAND: u32 = 0;

pub struct SwayBackend {
    socket: PathBuf,
    /// Path to the wflow binary that this daemon process is running
    /// from. Captured once at construction so `bindsym` dispatchers
    /// point at the right binary even if the user has multiple wflow
    /// installs on PATH.
    wflow_bin: PathBuf,
}

impl SwayBackend {
    pub fn new() -> Self {
        let socket = socket_path().expect(
            "SwayBackend constructed without SWAYSOCK — check is_available() first",
        );
        let wflow_bin = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("wflow"));
        Self { socket, wflow_bin }
    }

    fn run_command(&self, payload: &str) -> Result<()> {
        let mut stream = UnixStream::connect(&self.socket).with_context(|| {
            format!("connect Sway socket {}", self.socket.display())
        })?;

        let body = payload.as_bytes();
        let len: u32 = body.len() as u32;
        stream.write_all(MAGIC).context("write Sway magic")?;
        stream
            .write_all(&len.to_le_bytes())
            .context("write Sway payload length")?;
        stream
            .write_all(&TYPE_RUN_COMMAND.to_le_bytes())
            .context("write Sway payload type")?;
        stream.write_all(body).context("write Sway payload")?;

        // Read header + body. The reply type echoes the request type.
        let mut magic = [0u8; 6];
        stream.read_exact(&mut magic).context("read Sway magic")?;
        if &magic != MAGIC {
            return Err(anyhow!("sway: bad reply magic {magic:?}"));
        }
        let mut len_buf = [0u8; 4];
        let mut type_buf = [0u8; 4];
        stream
            .read_exact(&mut len_buf)
            .context("read Sway reply length")?;
        stream
            .read_exact(&mut type_buf)
            .context("read Sway reply type")?;
        let reply_len = u32::from_le_bytes(len_buf) as usize;
        let mut reply = vec![0u8; reply_len];
        stream
            .read_exact(&mut reply)
            .context("read Sway reply body")?;

        // RUN_COMMAND replies are JSON arrays of `{success, error}`.
        // Cheap parse: succeed when every element has `"success":true`.
        // Treat any malformed response as a hard error to surface
        // unexpected sway behavior loudly rather than silently.
        let text = std::str::from_utf8(&reply).context("sway reply utf-8")?;
        if !text.contains("\"success\":true") {
            return Err(anyhow!("sway rejected command {payload:?}: {text}"));
        }
        if text.contains("\"success\":false") {
            return Err(anyhow!("sway partial failure for {payload:?}: {text}"));
        }
        Ok(())
    }
}

impl Backend for SwayBackend {
    fn name(&self) -> &'static str {
        "sway"
    }

    fn bind(&mut self, b: &Binding) -> Result<()> {
        let chord = match &b.trigger.kind {
            TriggerKind::Chord { chord } => chord,
            _ => return Err(anyhow!("sway backend: only chord triggers supported today")),
        };
        let sway_chord = translate_chord(chord)?;

        // Evict any pre-existing bind for this chord first. Sway's
        // `bindsym` rejects a duplicate binding outright (the
        // `success: false` reply we'd otherwise propagate as an
        // error), so we always unbind speculatively. Failure means
        // the chord wasn't bound — fine. Same "wflow binds
        // supersede" model Hyprland uses; user's sway config bind
        // comes back on `swaymsg reload` after the daemon stops.
        let unbind_cmd = format!("unbindsym {sway_chord}");
        if let Err(e) = self.run_command(&unbind_cmd) {
            tracing::debug!(chord, %e, "pre-bind unbind failed (chord likely not bound)");
        }

        let cmd = format!(
            "bindsym {sway_chord} exec {} run {} --yes",
            self.wflow_bin.display(),
            b.workflow_id,
        );
        self.run_command(&cmd)
    }

    fn unbind(&mut self, b: &Binding) -> Result<()> {
        let chord = match &b.trigger.kind {
            TriggerKind::Chord { chord } => chord,
            _ => return Ok(()),
        };
        let sway_chord = translate_chord(chord)?;
        let cmd = format!("unbindsym {sway_chord}");
        if let Err(e) = self.run_command(&cmd) {
            tracing::warn!(chord, error = %e, "sway unbind failed");
        }
        Ok(())
    }
}

/// True when `$SWAYSOCK` points at a live socket we can talk to.
pub fn is_available() -> bool {
    socket_path().map(|p| p.exists()).unwrap_or(false)
}

fn socket_path() -> Option<PathBuf> {
    std::env::var("SWAYSOCK").ok().map(PathBuf::from)
}

/// Translate wflow's chord syntax (`super+alt+d`) into Sway's
/// (`Mod4+Mod1+d`). Modifiers Sway recognizes as keysym names: `Mod1`
/// (Alt), `Mod4` (Super/Logo), `Ctrl`, `Shift`. The leaf key is a
/// keysym; lowercase letters / digits / named keys (Return, F1,
/// Page_Up) round-trip with wflow's existing wdotool keysyms.
fn translate_chord(chord: &str) -> Result<String> {
    let parts: Vec<&str> = chord.split('+').map(str::trim).filter(|s| !s.is_empty()).collect();
    if parts.is_empty() {
        return Err(anyhow!("empty chord"));
    }
    let (key, mods) = parts.split_last().unwrap();
    let mod_strs: Vec<&'static str> = mods
        .iter()
        .map(|m| match m.to_ascii_lowercase().as_str() {
            "super" | "win" | "windows" | "logo" | "mod4" => Ok("Mod4"),
            "ctrl" | "control" => Ok("Ctrl"),
            "alt" | "meta" | "mod1" => Ok("Mod1"),
            "shift" => Ok("Shift"),
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
        assert_eq!(translate_chord("super+alt+d").unwrap(), "Mod4+Mod1+d");
    }

    #[test]
    fn translates_ctrl_shift_letter() {
        assert_eq!(translate_chord("ctrl+shift+u").unwrap(), "Ctrl+Shift+u");
    }

    #[test]
    fn passes_through_named_keys() {
        assert_eq!(translate_chord("ctrl+Return").unwrap(), "Ctrl+Return");
    }

    #[test]
    fn bare_key_no_modifiers() {
        assert_eq!(translate_chord("F1").unwrap(), "F1");
    }

    #[test]
    fn unknown_modifier_errors() {
        let err = translate_chord("hyper+a").unwrap_err().to_string();
        assert!(err.contains("hyper"), "{err}");
    }
}
