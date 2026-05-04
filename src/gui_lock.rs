//! Single-instance lock + URL-forwarding socket for the GUI.
//!
//! Why this exists: `wflow://...` deeplinks (sign-in callback,
//! workflow import) come through `xdg-open`, which reads the
//! `.desktop` file's `Exec=wflow %u` line and spawns a fresh wflow
//! process with the URL as an argument. Without single-instance
//! enforcement that means a second wflow window pops up every time
//! a deeplink fires, the original window's pending state (a nonce
//! waiting for its sign-in callback, say) is invisible to the new
//! process, and the user is stuck.
//!
//! The pattern: pidfile at `$XDG_RUNTIME_DIR/wflow/gui.pid` + Unix
//! socket at `$XDG_RUNTIME_DIR/wflow/gui.sock`. On startup wflow
//! tries to acquire the pidfile. If acquired, it's the first
//! instance; binds the socket, listens for URLs, runs the GUI. If
//! the pidfile's already held by a live process, wflow is a
//! forwarder: connects to the socket, writes the URL it received,
//! exits clean. The original instance's listener thread receives
//! the URL and hands it to the QML deeplink router via cxx-qt's
//! Qt-thread queue.
//!
//! Mirrors `daemon_lock.rs`'s pidfile shape — same `/proc/$pid`
//! liveness check, same drop-on-clean-exit behaviour. The socket
//! file is unlinked alongside.

use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver};
use std::time::Duration;

use anyhow::{Context, Result};

pub struct LockGuard {
    pidfile_path: PathBuf,
    socket_path: PathBuf,
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.pidfile_path);
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

pub enum AcquireOutcome {
    /// First instance — installs the pidfile, binds the socket,
    /// returns the guard plus the URL receiver. Caller is expected
    /// to keep the guard alive (drops unlink the files) and pump
    /// URLs out of the receiver into the QML deeplink router.
    Acquired(LockGuard, Receiver<String>),
    AlreadyRunning { pid: u32 },
}

/// Acquire the GUI lock. Spawns a listener thread on success that
/// pushes received URLs through the returned `url_rx`. Returns
/// `AlreadyRunning` when another wflow GUI is alive — caller is
/// expected to forward its deeplink (if any) via `forward_url` and
/// exit.
pub fn try_acquire() -> Result<AcquireOutcome> {
    let pidfile = pidfile_path().context("no XDG_RUNTIME_DIR — can't place gui pidfile")?;
    let socket = socket_path().context("no XDG_RUNTIME_DIR — can't place gui socket")?;
    try_acquire_at(&pidfile, &socket, &|p| process_alive(p))
}

/// Test-injectable variant. Path-pair + liveness check come from the
/// caller so tests don't need to touch real `$XDG_RUNTIME_DIR`.
fn try_acquire_at(
    pidfile_path: &PathBuf,
    socket_path: &PathBuf,
    alive: &dyn Fn(u32) -> bool,
) -> Result<AcquireOutcome> {
    if let Some(parent) = pidfile_path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("create runtime dir {}", parent.display()))?;
    }

    if let Ok(mut f) = std::fs::File::open(pidfile_path) {
        let mut buf = String::new();
        let _ = f.read_to_string(&mut buf);
        if let Ok(pid) = buf.trim().parse::<u32>() {
            if pid != std::process::id() && alive(pid) {
                return Ok(AcquireOutcome::AlreadyRunning { pid });
            }
        }
    }

    // Stale or missing pidfile + socket — overwrite both. A stale
    // socket will refuse a `bind` until we unlink it; do that
    // unconditionally now that we've decided the previous owner is
    // gone.
    let _ = std::fs::remove_file(socket_path);

    let mut f = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(pidfile_path)
        .with_context(|| format!("write pidfile {}", pidfile_path.display()))?;
    writeln!(f, "{}", std::process::id())
        .with_context(|| format!("write pidfile {}", pidfile_path.display()))?;

    let listener = UnixListener::bind(socket_path)
        .with_context(|| format!("bind gui socket {}", socket_path.display()))?;

    let (url_tx, url_rx) = channel::<String>();

    // Listener thread. Reads each incoming connection's bytes as one
    // URL, pushes through the channel, closes the connection. Each
    // wflow forwarder writes once and disconnects; we never expect
    // a long-running stream here.
    std::thread::Builder::new()
        .name("wflow-deeplink-listener".into())
        .spawn(move || {
            for conn in listener.incoming() {
                match conn {
                    Ok(mut stream) => {
                        let mut buf = String::new();
                        if let Err(e) = stream.read_to_string(&mut buf) {
                            tracing::warn!(?e, "deeplink listener: read failed");
                            continue;
                        }
                        let trimmed = buf.trim();
                        if trimmed.is_empty() {
                            continue;
                        }
                        if let Err(e) = url_tx.send(trimmed.to_string()) {
                            // Receiver gone — main thread shut down.
                            tracing::info!(?e, "deeplink listener: receiver dropped, exiting");
                            return;
                        }
                    }
                    Err(e) => {
                        tracing::warn!(?e, "deeplink listener: accept failed");
                    }
                }
            }
        })
        .context("spawn deeplink listener thread")?;

    Ok(AcquireOutcome::Acquired(
        LockGuard {
            pidfile_path: pidfile_path.clone(),
            socket_path: socket_path.clone(),
        },
        url_rx,
    ))
}

/// Send a deeplink URL to the running wflow GUI's listener. Retries a
/// handful of times with a short backoff so a forwarder racing the
/// listener-bind on cold start doesn't fail spuriously.
pub fn forward_url(url: &str) -> Result<()> {
    let path = socket_path().context("no XDG_RUNTIME_DIR — can't locate gui socket")?;

    let mut last_err: Option<anyhow::Error> = None;
    for attempt in 0..6 {
        match UnixStream::connect(&path) {
            Ok(mut sock) => {
                sock.write_all(url.as_bytes()).context("write URL to socket")?;
                return Ok(());
            }
            Err(e) => {
                last_err = Some(anyhow::anyhow!("connect {}: {e}", path.display()));
                std::thread::sleep(Duration::from_millis(150 * (attempt + 1) as u64));
            }
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow::anyhow!("forward URL: unreachable")))
}

fn pidfile_path() -> Option<PathBuf> {
    let runtime = std::env::var("XDG_RUNTIME_DIR").ok()?;
    if runtime.is_empty() {
        return None;
    }
    Some(PathBuf::from(runtime).join("wflow").join("gui.pid"))
}

fn socket_path() -> Option<PathBuf> {
    let runtime = std::env::var("XDG_RUNTIME_DIR").ok()?;
    if runtime.is_empty() {
        return None;
    }
    Some(PathBuf::from(runtime).join("wflow").join("gui.sock"))
}

fn process_alive(pid: u32) -> bool {
    std::path::Path::new(&format!("/proc/{pid}")).exists()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn paths(dir: &TempDir) -> (PathBuf, PathBuf) {
        (
            dir.path().join("gui.pid"),
            dir.path().join("gui.sock"),
        )
    }

    #[test]
    fn fresh_acquire_succeeds() {
        let dir = tempfile::tempdir().unwrap();
        let (pid, sock) = paths(&dir);
        match try_acquire_at(&pid, &sock, &|_| false).unwrap() {
            AcquireOutcome::Acquired(_g, _rx) => assert!(pid.exists()),
            AcquireOutcome::AlreadyRunning { .. } => panic!("should have acquired"),
        }
    }

    #[test]
    fn live_pid_blocks_acquire() {
        let dir = tempfile::tempdir().unwrap();
        let (pid, sock) = paths(&dir);
        std::fs::write(&pid, b"99999\n").unwrap();
        match try_acquire_at(&pid, &sock, &|_| true).unwrap() {
            AcquireOutcome::AlreadyRunning { pid: 99999 } => {}
            _ => panic!("should have been blocked"),
        }
    }

    #[test]
    fn stale_pid_is_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let (pid, sock) = paths(&dir);
        std::fs::write(&pid, b"77777\n").unwrap();
        match try_acquire_at(&pid, &sock, &|_| false).unwrap() {
            AcquireOutcome::Acquired(_g, _rx) => {}
            _ => panic!("stale pid should have been overwritten"),
        }
    }

    #[test]
    fn forward_url_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let (pid, sock) = paths(&dir);
        let (_guard, url_rx) = match try_acquire_at(&pid, &sock, &|_| false).unwrap() {
            AcquireOutcome::Acquired(g, rx) => (g, rx),
            _ => panic!("acquire failed"),
        };

        // Forwarder mimics what main.rs does: connect to the socket
        // path and write the URL.
        let url = "wflow://auth/callback?nonce=abc&token=xyz";
        let mut stream = UnixStream::connect(&sock).unwrap();
        stream.write_all(url.as_bytes()).unwrap();
        drop(stream);

        let received = url_rx
            .recv_timeout(Duration::from_millis(500))
            .expect("listener should receive URL");
        assert_eq!(received, url);
    }
}
