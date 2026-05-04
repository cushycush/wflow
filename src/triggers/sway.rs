//! Sway IPC backend (i3 protocol over `$SWAYSOCK`). Frame layout per
//! `sway-ipc(7)`. We talk to the socket directly so a missing
//! `swaymsg` doesn't break the daemon.

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
    /// Captured at construction so dispatchers stay pinned to this
    /// daemon's wflow binary.
    wflow_bin: PathBuf,
}

impl SwayBackend {
    pub fn new() -> Self {
        let socket = socket_path().expect(
            "SwayBackend constructed without SWAYSOCK, check is_available() first",
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
        // Cheap success match on `"success":true`.
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

        // Sway's `bindsym` rejects duplicates; unbind speculatively.
        let unbind_cmd = format!("unbindsym {sway_chord}");
        if let Err(e) = self.run_command(&unbind_cmd) {
            tracing::debug!(chord, %e, "pre-bind unbind failed (chord likely not bound)");
        }

        let cmd = format!(
            "bindsym {sway_chord} exec {} trigger-fire {}",
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

/// `super+alt+d` → `Mod4+Mod1+d`. Sway modifier keysyms: `Mod4`,
/// `Mod1`, `Ctrl`, `Shift`.
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
