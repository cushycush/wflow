//! `~/.config/wflow/state.toml`. Onboarding flags, theme, palette,
//! workflows-dir override, sign-in snapshot. Parse errors back the
//! file up to `state.toml.broken-<ts>` and reset to defaults.

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct State {
    #[serde(default = "default_schema")]
    pub schema: u32,
    #[serde(default)]
    pub first_run_at: Option<String>,
    #[serde(default)]
    pub tutorials: BTreeMap<String, bool>,
    /// "auto" | "light" | "dark".
    #[serde(default = "default_theme_mode")]
    pub theme_mode: String,
    /// Brand palette: "warm" (warm-paper + coral, mirrors wflows.com)
    /// or "cool" (slate-blue surfaces + amber, the original wflow
    /// brand). Defaults to "warm" because that's the published
    /// marketing-site identity; the first-run tutorial offers the
    /// user a chance to flip it before they ever see Library.
    #[serde(default = "default_palette")]
    pub palette: String,
    #[serde(default)]
    pub reduce_motion: bool,
    /// "recent" | "name" | "last_run".
    #[serde(default = "default_library_sort")]
    pub library_sort: String,
    /// `None` = XDG default. Stored as String so a cross-platform port
    /// doesn't have to carry PathBuf-shaped TOML.
    #[serde(default)]
    pub workflows_dir: Option<String>,
}

fn default_schema() -> u32 {
    1
}

fn default_theme_mode() -> String {
    "auto".to_string()
}

fn default_palette() -> String {
    "warm".to_string()
}

fn default_library_sort() -> String {
    "recent".to_string()
}

impl Default for State {
    fn default() -> Self {
        Self {
            schema: 1,
            first_run_at: None,
            tutorials: BTreeMap::new(),
            theme_mode: default_theme_mode(),
            palette: default_palette(),
            reduce_motion: false,
            library_sort: default_library_sort(),
            workflows_dir: None,
        }
    }
}

impl State {
    pub fn is_first_run(&self) -> bool {
        self.first_run_at.is_none()
    }

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

fn state_path() -> Result<PathBuf> {
    if let Ok(p) = std::env::var("WFLOW_STATE_PATH") {
        return Ok(PathBuf::from(p));
    }
    let dir = dirs::config_dir()
        .context("no XDG_CONFIG_HOME or HOME, cannot locate state.toml")?
        .join("wflow");
    Ok(dir.join("state.toml"))
}

/// Never fails. Parse errors back the broken file up.
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

/// Best-effort. Worst case the user sees a tutorial again next launch.
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
    fn palette_defaults_to_warm_and_round_trips() {
        let _g = setup();
        // A v0.4.x state file (no palette key) must load.
        let path = PathBuf::from(std::env::var("WFLOW_STATE_PATH").unwrap());
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "schema = 1\n").unwrap();
        let loaded = load();
        assert_eq!(loaded.palette, "warm");

        let mut s = State::default();
        s.palette = "cool".to_string();
        save(&s);
        let again = load();
        assert_eq!(again.palette, "cool");
    }

    #[test]
    fn tutorial_seen_unknown_is_false() {
        let s = State::default();
        assert!(!s.tutorial_seen("never-heard-of-it"));
    }
}
