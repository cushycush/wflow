//! Single-instance lock for `wflow daemon`.
//!
//! The model is a pidfile under `$XDG_RUNTIME_DIR/wflow/daemon.pid`.
//! On acquire we check whether the pid in the existing file is still
//! alive (via `/proc/$pid`). If it is, we refuse and let the caller
//! print "already running, pid N". If the pid is dead — crash, kill,
//! reboot — we treat the file as stale and overwrite it with our own
//! pid. On drop we unlink the file so a clean shutdown leaves no
//! trace.
//!
//! There's a microsecond TOCTOU window between read-and-check and
//! write where two simultaneous starts could both win. We don't
//! defend against it: the worst case is the loser's portal /
//! compositor-IPC bind fails (chord already bound) and it exits with
//! a normal error. Adding `flock` would fix it but pulls in a
//! syscall we don't otherwise need; the simple path is fine for
//! "make sure two daemons can't both run by accident."

use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::path::PathBuf;

use anyhow::{Context, Result};

pub struct LockGuard {
    path: PathBuf,
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

pub enum AcquireOutcome {
    Acquired(LockGuard),
    AlreadyRunning { pid: u32 },
}

/// Acquire the daemon lock. Returns `AlreadyRunning { pid }` when an
/// existing daemon is alive, otherwise installs our own pidfile and
/// hands back a guard.
pub fn try_acquire() -> Result<AcquireOutcome> {
    let path = pidfile_path().context("no XDG_RUNTIME_DIR — can't place daemon pidfile")?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("create runtime dir {}", parent.display()))?;
    }

    if let Ok(mut f) = std::fs::File::open(&path) {
        let mut buf = String::new();
        let _ = f.read_to_string(&mut buf);
        if let Ok(pid) = buf.trim().parse::<u32>() {
            if pid != std::process::id() && process_alive(pid) {
                return Ok(AcquireOutcome::AlreadyRunning { pid });
            }
        }
    }

    let mut f = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&path)
        .with_context(|| format!("write pidfile {}", path.display()))?;
    writeln!(f, "{}", std::process::id())
        .with_context(|| format!("write pidfile {}", path.display()))?;

    Ok(AcquireOutcome::Acquired(LockGuard { path }))
}

fn pidfile_path() -> Option<PathBuf> {
    let runtime = std::env::var("XDG_RUNTIME_DIR").ok()?;
    Some(PathBuf::from(runtime).join("wflow").join("daemon.pid"))
}

fn process_alive(pid: u32) -> bool {
    PathBuf::from(format!("/proc/{pid}")).exists()
}
