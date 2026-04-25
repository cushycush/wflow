//! UX onboarding state at `~/.config/wflow/state.toml`.
//!
//! Tracks "have we seen this user before" and "has the user already
//! seen tutorial X." Lives separate from `src/store.rs` (which owns
//! workflow files) so the two concerns don't tangle.
//!
//! Resilience: parse errors NEVER crash the app. A broken file is
//! backed up as `state.toml.broken-<unix-ts>` and the in-memory state
//! resets to defaults. Worst case the user sees a tutorial overlay
//! once more than necessary.
//!
//! Atomic writes via `tempfile::NamedTempFile::persist()` so a crash
//! mid-write can't corrupt the active file.

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct State {
    /// Reserved for future migrations. Schema 1 == this layout.
    #[serde(default = "default_schema")]
    pub schema: u32,
    /// First time the user opened wflow on this machine, or None on
    /// a freshly-installed system that hasn't booted yet.
    #[serde(default)]
    pub first_run_at: Option<String>,
    /// Per-tutorial dismissal flags. Map keys are stable IDs like
    /// `"blank_workflow"`. Missing key == not seen.
    #[serde(default)]
    pub tutorials: BTreeMap<String, bool>,
}

fn default_schema() -> u32 {
    1
}

impl Default for State {
    fn default() -> Self {
        Self {
            schema: 1,
            first_run_at: None,
            tutorials: BTreeMap::new(),
        }
    }
}

impl State {
    /// True the very first time the app runs on this machine.
    pub fn is_first_run(&self) -> bool {
        self.first_run_at.is_none()
    }

    /// Mark the first-run timestamp. No-op if already set.
    pub fn mark_first_run_seen(&mut self) {
        if self.first_run_at.is_none() {
            self.first_run_at = Some(chrono::Utc::now().to_rfc3339());
        }
    }

    pub fn tutorial_seen(&self, name: &str) -> bool {
        self.tutorials.get(name).copied().unwrap_or(false)
    }

    pub fn mark_tutorial_seen(&mut self, name: &str) {
        self.tutorials.insert(name.to_string(), true);
    }
}

/// Path to `state.toml`. Tests override via `WFLOW_STATE_PATH` so they
/// don't touch the real config dir.
fn state_path() -> Result<PathBuf> {
    if let Ok(p) = std::env::var("WFLOW_STATE_PATH") {
        return Ok(PathBuf::from(p));
    }
    let dir = dirs::config_dir()
        .context("no XDG_CONFIG_HOME or HOME — cannot locate state.toml")?
        .join("wflow");
    Ok(dir.join("state.toml"))
}

/// Load state from disk. Missing file or unparseable file both return
/// `Ok(default)` — this function never fails the app's startup. On
/// parse failure, the broken file is renamed to
/// `state.toml.broken-<ts>` so the user can inspect it later.
pub fn load() -> State {
    let path = match state_path() {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!("could not locate state.toml: {e:#}; using defaults");
            return State::default();
        }
    };

    let bytes = match fs::read(&path) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return State::default();
        }
        Err(e) => {
            tracing::warn!("could not read {}: {e}; using defaults", path.display());
            return State::default();
        }
    };

    let text = match std::str::from_utf8(&bytes) {
        Ok(s) => s,
        Err(_) => {
            backup_broken(&path);
            return State::default();
        }
    };

    match toml::from_str::<State>(text) {
        Ok(s) if s.schema == 1 => s,
        Ok(s) => {
            tracing::warn!(
                "state.toml schema {} is newer than supported (1); using defaults to avoid corruption",
                s.schema
            );
            backup_broken(&path);
            State::default()
        }
        Err(e) => {
            tracing::warn!("state.toml parse error: {e}; using defaults");
            backup_broken(&path);
            State::default()
        }
    }
}

/// Write state to disk via atomic tempfile rename. Failure is logged
/// but never bubbles up — at worst the state isn't persisted, the
/// user gets a tutorial again next launch.
pub fn save(state: &State) {
    let path = match state_path() {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!("could not locate state.toml: {e:#}; skipping save");
            return;
        }
    };

    if let Some(parent) = path.parent() {
        if let Err(e) = fs::create_dir_all(parent) {
            tracing::warn!("could not create {}: {e}; skipping save", parent.display());
            return;
        }
    }

    let body = match toml::to_string_pretty(state) {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!("could not serialize state: {e}; skipping save");
            return;
        }
    };

    // Atomic write via tempfile + rename in the same directory.
    let tmp = path.with_extension("toml.tmp");
    if let Err(e) = fs::write(&tmp, body.as_bytes()) {
        tracing::warn!(
            "could not write tempfile {}: {e}; skipping save",
            tmp.display()
        );
        return;
    }
    if let Err(e) = fs::rename(&tmp, &path) {
        tracing::warn!(
            "could not rename {} -> {}: {e}; skipping save",
            tmp.display(),
            path.display()
        );
        // Best-effort cleanup.
        let _ = fs::remove_file(&tmp);
    }
}

fn backup_broken(path: &std::path::Path) {
    let ts = chrono::Utc::now().timestamp();
    let backup = path.with_extension(format!("toml.broken-{ts}"));
    if let Err(e) = fs::rename(path, &backup) {
        tracing::warn!(
            "could not back up broken state file {} -> {}: {e}",
            path.display(),
            backup.display()
        );
    } else {
        tracing::warn!(
            "backed up unparseable state file to {}",
            backup.display()
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tempfile::TempDir;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct EnvGuard {
        _lock: std::sync::MutexGuard<'static, ()>,
        _dir: TempDir,
    }

    fn setup() -> EnvGuard {
        let lock = ENV_LOCK.lock().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.toml");
        std::env::set_var("WFLOW_STATE_PATH", &path);
        EnvGuard { _lock: lock, _dir: dir }
    }

    #[test]
    fn missing_file_returns_default() {
        let _g = setup();
        let s = load();
        assert!(s.is_first_run());
        assert!(!s.tutorial_seen("anything"));
    }

    #[test]
    fn round_trip_through_save_load() {
        let _g = setup();
        let mut s = State::default();
        s.mark_first_run_seen();
        s.mark_tutorial_seen("blank_workflow");
        save(&s);

        let loaded = load();
        assert!(!loaded.is_first_run());
        assert!(loaded.tutorial_seen("blank_workflow"));
        assert!(!loaded.tutorial_seen("other_tutorial"));
    }

    #[test]
    fn corrupt_file_backs_up_and_returns_default() {
        let _g = setup();
        let path = PathBuf::from(std::env::var("WFLOW_STATE_PATH").unwrap());
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "this is not toml at all }}{{").unwrap();

        let s = load();
        assert!(s.is_first_run());

        // Original file should be gone, a `.broken-<ts>` should exist.
        assert!(!path.exists(), "broken file should have been moved aside");
        let dir = path.parent().unwrap();
        let entries: Vec<_> = fs::read_dir(dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| {
                e.file_name()
                    .to_string_lossy()
                    .contains("state.toml.broken-")
            })
            .collect();
        assert_eq!(entries.len(), 1, "expected exactly one broken backup");
    }

    #[test]
    fn future_schema_is_rejected_safely() {
        let _g = setup();
        let path = PathBuf::from(std::env::var("WFLOW_STATE_PATH").unwrap());
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "schema = 99\n").unwrap();

        let s = load();
        assert_eq!(s.schema, 1, "default schema");
        assert!(s.is_first_run());
        // Broken backup should exist.
        assert!(!path.exists());
    }

    #[test]
    fn mark_first_run_seen_is_idempotent() {
        let mut s = State::default();
        s.mark_first_run_seen();
        let first = s.first_run_at.clone();
        std::thread::sleep(std::time::Duration::from_millis(10));
        s.mark_first_run_seen();
        assert_eq!(s.first_run_at, first, "second call should not overwrite");
    }

    #[test]
    fn tutorial_seen_unknown_is_false() {
        let s = State::default();
        assert!(!s.tutorial_seen("never-heard-of-it"));
    }
}
