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
    try_acquire_at(&path, &|p| process_alive(p))
}

/// Path-and-liveness-injectable variant. Tests call this directly with
/// a tempdir path and a stub liveness check so they don't have to mess
/// with `$XDG_RUNTIME_DIR` (which would race across parallel tests).
fn try_acquire_at(path: &PathBuf, alive: &dyn Fn(u32) -> bool) -> Result<AcquireOutcome> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("create runtime dir {}", parent.display()))?;
    }

    if let Ok(mut f) = std::fs::File::open(path) {
        let mut buf = String::new();
        let _ = f.read_to_string(&mut buf);
        if let Ok(pid) = buf.trim().parse::<u32>() {
            if pid != std::process::id() && alive(pid) {
                return Ok(AcquireOutcome::AlreadyRunning { pid });
            }
        }
    }

    let mut f = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(path)
        .with_context(|| format!("write pidfile {}", path.display()))?;
    writeln!(f, "{}", std::process::id())
        .with_context(|| format!("write pidfile {}", path.display()))?;

    Ok(AcquireOutcome::Acquired(LockGuard { path: path.clone() }))
}

fn pidfile_path() -> Option<PathBuf> {
    let runtime = std::env::var("XDG_RUNTIME_DIR").ok()?;
    Some(PathBuf::from(runtime).join("wflow").join("daemon.pid"))
}

fn process_alive(pid: u32) -> bool {
    PathBuf::from(format!("/proc/{pid}")).exists()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Make a unique temp pidfile path under the system temp dir.
    /// Avoids touching `XDG_RUNTIME_DIR`, which would race across
    /// parallel cargo tests.
    fn fresh_pidfile_path() -> PathBuf {
        let mut p = std::env::temp_dir();
        let suffix = format!(
            "wflow-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
        );
        p.push(suffix);
        p.push("wflow");
        p.push("daemon.pid");
        p
    }

    #[test]
    fn fresh_acquire_writes_pidfile_with_our_pid() {
        let path = fresh_pidfile_path();
        let outcome = try_acquire_at(&path, &|_| false).unwrap();
        match outcome {
            AcquireOutcome::Acquired(_g) => {
                assert!(path.exists());
                let body = std::fs::read_to_string(&path).unwrap();
                assert_eq!(body.trim(), std::process::id().to_string());
            }
            AcquireOutcome::AlreadyRunning { .. } => panic!("expected fresh acquire"),
        }
    }

    #[test]
    fn drop_removes_pidfile() {
        let path = fresh_pidfile_path();
        {
            let outcome = try_acquire_at(&path, &|_| false).unwrap();
            let _g = match outcome {
                AcquireOutcome::Acquired(g) => g,
                _ => panic!("expected acquire"),
            };
            assert!(path.exists());
        }
        // LockGuard's Drop ran. File should be gone.
        assert!(!path.exists(), "pidfile should be unlinked on drop");
    }

    #[test]
    fn live_pidfile_is_treated_as_already_running() {
        let path = fresh_pidfile_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        // Pretend pid 4242 holds the file and is alive.
        std::fs::write(&path, "4242\n").unwrap();
        let outcome = try_acquire_at(&path, &|p| p == 4242).unwrap();
        match outcome {
            AcquireOutcome::AlreadyRunning { pid } => assert_eq!(pid, 4242),
            AcquireOutcome::Acquired(_) => panic!("live pid should block acquire"),
        }
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn stale_pidfile_is_overwritten() {
        let path = fresh_pidfile_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        // Pretend pid 4243 wrote the file but is dead now.
        std::fs::write(&path, "4243\n").unwrap();
        let outcome = try_acquire_at(&path, &|_| false).unwrap();
        match outcome {
            AcquireOutcome::Acquired(_) => {
                let body = std::fs::read_to_string(&path).unwrap();
                assert_eq!(body.trim(), std::process::id().to_string());
            }
            _ => panic!("stale pid should let us acquire"),
        }
    }
}
