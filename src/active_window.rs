//! Probe the currently-focused window's class and title.
//!
//! Used by `wflow trigger-fire` to gate chord activation on the
//! `trigger { when ... }` predicate. The chord is bound globally
//! (Hyprland / Sway / GlobalShortcuts portal all bind compositor-wide)
//! so the wrapper has to do the per-fire window check itself.
//!
//! Backends in priority order:
//!   - Hyprland: `hyprctl activewindow -j` over IPC. Microsecond-fast.
//!   - Sway: `swaymsg -t get_tree -t -p` walked for the focused leaf.
//!
//! KDE Plasma 6 and GNOME 46+ aren't covered yet — they need a
//! vendor-specific D-Bus call (`org.kde.KWin` / `org.gnome.Shell`)
//! that varies by version. When the probe fails (no compositor
//! match, IPC error, missing socket) the gate falls open: the
//! workflow runs as if no predicate were set, on the principle that
//! a misfire is better than a silently dropped chord. Tracing logs
//! the reason so users can debug from the daemon journal.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

use anyhow::{anyhow, Context, Result};
use serde::Deserialize;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActiveWindow {
    pub class: String,
    pub title: String,
}

/// Probe the focused window via whichever compositor is reachable.
/// Returns `None` if no probe path is available — callers should
/// treat that as "open the gate" rather than failing closed, since
/// the alternative (silently dropping the chord) is the worse error.
pub fn probe() -> Option<ActiveWindow> {
    if let Some(w) = probe_hyprland() {
        return Some(w);
    }
    if let Some(w) = probe_sway() {
        return Some(w);
    }
    None
}

fn probe_hyprland() -> Option<ActiveWindow> {
    let his = std::env::var("HYPRLAND_INSTANCE_SIGNATURE").ok()?;
    let runtime = std::env::var("XDG_RUNTIME_DIR").ok()?;
    let socket = PathBuf::from(runtime)
        .join("hypr")
        .join(&his)
        .join(".socket.sock");
    match hyprland_active(&socket) {
        Ok(Some(w)) => Some(w),
        Ok(None) => None,
        Err(e) => {
            tracing::debug!(error = %e, "hyprland active-window probe failed");
            None
        }
    }
}

fn hyprland_active(socket: &std::path::Path) -> Result<Option<ActiveWindow>> {
    let mut stream = UnixStream::connect(socket)
        .with_context(|| format!("connect Hyprland socket {}", socket.display()))?;
    stream
        .write_all(b"j/activewindow")
        .context("write Hyprland activewindow request")?;
    stream
        .shutdown(std::net::Shutdown::Write)
        .context("close write half")?;
    let mut response = String::new();
    stream
        .read_to_string(&mut response)
        .context("read Hyprland activewindow response")?;
    let response = response.trim();
    // No focused window: Hyprland returns an empty object `{}`. The
    // serde decode lands an entirely-optional struct; treat all-None
    // as "no focus" rather than an error.
    if response.is_empty() || response == "{}" {
        return Ok(None);
    }
    #[derive(Deserialize)]
    struct Resp {
        #[serde(default)]
        class: Option<String>,
        #[serde(default)]
        title: Option<String>,
    }
    let r: Resp = serde_json::from_str(response)
        .with_context(|| format!("parse Hyprland activewindow JSON: {response}"))?;
    let class = r.class.unwrap_or_default();
    let title = r.title.unwrap_or_default();
    if class.is_empty() && title.is_empty() {
        return Ok(None);
    }
    Ok(Some(ActiveWindow { class, title }))
}

fn probe_sway() -> Option<ActiveWindow> {
    let socket_path = std::env::var("SWAYSOCK").ok()?;
    match sway_active(&PathBuf::from(socket_path)) {
        Ok(Some(w)) => Some(w),
        Ok(None) => None,
        Err(e) => {
            tracing::debug!(error = %e, "sway active-window probe failed");
            None
        }
    }
}

fn sway_active(socket: &std::path::Path) -> Result<Option<ActiveWindow>> {
    const MAGIC: &[u8; 6] = b"i3-ipc";
    const TYPE_GET_TREE: u32 = 4;

    let mut stream = UnixStream::connect(socket)
        .with_context(|| format!("connect Sway socket {}", socket.display()))?;

    stream.write_all(MAGIC).context("write Sway magic")?;
    stream
        .write_all(&0u32.to_le_bytes())
        .context("write Sway payload length")?;
    stream
        .write_all(&TYPE_GET_TREE.to_le_bytes())
        .context("write Sway payload type")?;

    let mut magic = [0u8; 6];
    stream.read_exact(&mut magic).context("read Sway magic")?;
    if &magic != MAGIC {
        return Err(anyhow!("sway: bad reply magic {magic:?}"));
    }
    let mut len_buf = [0u8; 4];
    let mut type_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).context("read Sway reply length")?;
    stream.read_exact(&mut type_buf).context("read Sway reply type")?;
    let reply_len = u32::from_le_bytes(len_buf) as usize;
    let mut reply = vec![0u8; reply_len];
    stream.read_exact(&mut reply).context("read Sway reply body")?;

    let v: serde_json::Value =
        serde_json::from_slice(&reply).context("parse Sway tree JSON")?;

    Ok(focused_leaf(&v))
}

/// Walk a Sway tree for the focused leaf. The focused window is the
/// first node where `focused == true`. Picks `app_id` first
/// (Wayland-native) and falls back to `window_properties.class`
/// (xwayland clients).
fn focused_leaf(node: &serde_json::Value) -> Option<ActiveWindow> {
    if node.get("focused").and_then(|f| f.as_bool()) == Some(true) {
        let class = node
            .get("app_id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .or_else(|| {
                node.get("window_properties")
                    .and_then(|w| w.get("class"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            })
            .unwrap_or_default();
        let title = node
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        return Some(ActiveWindow { class, title });
    }
    for key in ["nodes", "floating_nodes"] {
        if let Some(arr) = node.get(key).and_then(|v| v.as_array()) {
            for child in arr {
                if let Some(w) = focused_leaf(child) {
                    return Some(w);
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sway_focused_leaf_finds_focused_node() {
        let tree = serde_json::json!({
            "focused": false,
            "nodes": [
                {
                    "focused": false,
                    "nodes": [
                        {
                            "focused": true,
                            "app_id": "firefox",
                            "name": "Mozilla Firefox",
                        }
                    ],
                    "floating_nodes": [],
                }
            ],
            "floating_nodes": [],
        });
        let w = focused_leaf(&tree).expect("focused leaf");
        assert_eq!(w.class, "firefox");
        assert_eq!(w.title, "Mozilla Firefox");
    }

    #[test]
    fn sway_focused_leaf_falls_back_to_xwayland_class() {
        let tree = serde_json::json!({
            "focused": false,
            "nodes": [{
                "focused": true,
                "name": "Slack",
                "window_properties": { "class": "Slack" },
            }],
            "floating_nodes": [],
        });
        let w = focused_leaf(&tree).expect("focused leaf");
        assert_eq!(w.class, "Slack");
        assert_eq!(w.title, "Slack");
    }

    #[test]
    fn sway_focused_leaf_returns_none_when_no_focus() {
        let tree = serde_json::json!({
            "focused": false,
            "nodes": [{
                "focused": false,
                "nodes": [],
                "floating_nodes": [],
            }],
            "floating_nodes": [],
        });
        assert!(focused_leaf(&tree).is_none());
    }
}
