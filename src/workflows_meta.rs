//! Per-workflow metadata sidecar at `~/.config/wflow/workflows.toml`.
//!
//! Holds `created` / `modified` / `last_run` timestamps that used to
//! ride inside each `.kdl` file. Splitting them out keeps the workflow
//! file a pure spec — git diffs of a `.kdl` show the steps the user
//! changed, not the modified-time the engine bumped on its last run.
//!
//! Schema:
//!
//! ```toml
//! schema = 1
//!
//! [meta."example-dev-setup"]
//! created  = "2026-04-25T..."
//! modified = "2026-04-25T..."
//! last_run = "2026-04-26T..."
//! ```
//!
//! Resilience: parse errors NEVER crash the app. A broken file is
//! backed up as `workflows.toml.broken-<unix-ts>` and the in-memory
//! state resets to defaults — same recovery the state.toml loader
//! does (`crate::state`).

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct WorkflowMeta {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub modified: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_run: Option<DateTime<Utc>>,
    /// Canvas card positions, keyed by step id. Set by the GUI when
    /// the user drags cards on the workflow canvas; loaded back to
    /// restore the layout on reopen.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub card_positions: BTreeMap<String, [f64; 2]>,
}

impl WorkflowMeta {
    pub fn is_empty(&self) -> bool {
        self.created.is_none()
            && self.modified.is_none()
            && self.last_run.is_none()
            && self.card_positions.is_empty()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct File {
    #[serde(default = "default_schema")]
    schema: u32,
    #[serde(default)]
    meta: BTreeMap<String, WorkflowMeta>,
}

fn default_schema() -> u32 {
    1
}

impl Default for File {
    fn default() -> Self {
        Self {
            schema: 1,
            meta: BTreeMap::new(),
        }
    }
}

fn path() -> Result<PathBuf> {
    if let Ok(p) = std::env::var("WFLOW_WORKFLOWS_META_PATH") {
        return Ok(PathBuf::from(p));
    }
    let dir = dirs::config_dir()
        .context("no XDG_CONFIG_HOME or HOME — cannot locate workflows.toml")?
        .join("wflow");
    Ok(dir.join("workflows.toml"))
}

/// Read the entire file. Returns defaults on any failure (missing,
/// unreadable, unparseable). A broken file is backed up before being
/// replaced by defaults.
fn load_file() -> File {
    let path = match path() {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!("could not locate workflows.toml: {e:#}; using defaults");
            return File::default();
        }
    };

    let bytes = match fs::read(&path) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return File::default(),
        Err(e) => {
            tracing::warn!("could not read {}: {e}; using defaults", path.display());
            return File::default();
        }
    };

    let text = match std::str::from_utf8(&bytes) {
        Ok(s) => s,
        Err(_) => {
            backup_broken(&path);
            return File::default();
        }
    };

    match toml::from_str::<File>(text) {
        Ok(f) if f.schema == 1 => f,
        Ok(f) => {
            tracing::warn!(
                "workflows.toml schema {} is newer than supported (1); using defaults",
                f.schema
            );
            backup_broken(&path);
            File::default()
        }
        Err(e) => {
            tracing::warn!("workflows.toml parse error: {e}; using defaults");
            backup_broken(&path);
            File::default()
        }
    }
}

fn save_file(file: &File) {
    let p = match path() {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!("could not locate workflows.toml: {e:#}; skipping save");
            return;
        }
    };
    if let Some(parent) = p.parent() {
        if let Err(e) = fs::create_dir_all(parent) {
            tracing::warn!("could not create {}: {e}; skipping save", parent.display());
            return;
        }
    }

    let body = match toml::to_string_pretty(file) {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!("could not serialize workflows.toml: {e}; skipping save");
            return;
        }
    };

    let tmp = p.with_extension("toml.tmp");
    if let Err(e) = fs::write(&tmp, body.as_bytes()) {
        tracing::warn!(
            "could not write tempfile {}: {e}; skipping save",
            tmp.display()
        );
        return;
    }
    if let Err(e) = fs::rename(&tmp, &p) {
        tracing::warn!(
            "could not rename {} -> {}: {e}; skipping save",
            tmp.display(),
            p.display()
        );
        let _ = fs::remove_file(&tmp);
    }
}

fn backup_broken(path: &std::path::Path) {
    let ts = chrono::Utc::now().timestamp();
    let backup = path.with_extension(format!("toml.broken-{ts}"));
    if let Err(e) = fs::rename(path, &backup) {
        tracing::warn!(
            "could not back up broken workflows.toml {} -> {}: {e}",
            path.display(),
            backup.display()
        );
    } else {
        tracing::warn!(
            "backed up unparseable workflows.toml to {}",
            backup.display()
        );
    }
}

/// Get one workflow's metadata. None if no entry exists.
pub fn get(id: &str) -> Option<WorkflowMeta> {
    load_file().meta.remove(id)
}

/// Replace one workflow's metadata. Empty struct removes the entry.
pub fn set(id: &str, meta: WorkflowMeta) {
    let mut file = load_file();
    if meta.is_empty() {
        file.meta.remove(id);
    } else {
        file.meta.insert(id.to_string(), meta);
    }
    save_file(&file);
}

/// Drop one workflow's metadata. No-op if not present.
pub fn remove(id: &str) {
    let mut file = load_file();
    if file.meta.remove(id).is_some() {
        save_file(&file);
    }
}

/// Update only the `last_run` timestamp on a workflow's entry,
/// preserving everything else. Creates the entry if missing.
pub fn touch_last_run(id: &str) {
    let mut file = load_file();
    let entry = file.meta.entry(id.to_string()).or_default();
    entry.last_run = Some(chrono::Utc::now());
    save_file(&file);
}

/// Replace the card-positions map on a workflow's entry, preserving
/// other fields. Empty map clears the entry's positions.
pub fn set_positions(id: &str, positions: BTreeMap<String, [f64; 2]>) {
    let mut file = load_file();
    let entry = file.meta.entry(id.to_string()).or_default();
    entry.card_positions = positions;
    if entry.is_empty() {
        file.meta.remove(id);
    }
    save_file(&file);
}

/// Read just the card-positions map for a workflow. Returns an empty
/// map if the entry doesn't exist or has no positions.
pub fn get_positions(id: &str) -> BTreeMap<String, [f64; 2]> {
    load_file()
        .meta
        .get(id)
        .map(|m| m.card_positions.clone())
        .unwrap_or_default()
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
        std::env::set_var(
            "WFLOW_WORKFLOWS_META_PATH",
            dir.path().join("workflows.toml"),
        );
        EnvGuard {
            _lock: lock,
            _dir: dir,
        }
    }

    #[test]
    fn missing_file_returns_none() {
        let _g = setup();
        assert!(get("anything").is_none());
    }

    #[test]
    fn set_and_get_round_trip() {
        let _g = setup();
        let now = chrono::Utc::now();
        set(
            "wf-1",
            WorkflowMeta {
                created: Some(now),
                modified: Some(now),
                last_run: None,
                card_positions: BTreeMap::new(),
            },
        );
        let loaded = get("wf-1").unwrap();
        assert_eq!(loaded.created, Some(now));
        assert_eq!(loaded.modified, Some(now));
        assert_eq!(loaded.last_run, None);
    }

    #[test]
    fn touch_last_run_preserves_other_fields() {
        let _g = setup();
        let then = chrono::Utc::now() - chrono::Duration::days(1);
        set(
            "wf-1",
            WorkflowMeta {
                created: Some(then),
                modified: Some(then),
                last_run: None,
                card_positions: BTreeMap::new(),
            },
        );

        touch_last_run("wf-1");

        let loaded = get("wf-1").unwrap();
        assert_eq!(loaded.created, Some(then));
        assert_eq!(loaded.modified, Some(then));
        assert!(loaded.last_run.is_some());
        assert!(loaded.last_run.unwrap() > then);
    }

    #[test]
    fn touch_last_run_creates_missing_entry() {
        let _g = setup();
        touch_last_run("never-existed");
        let loaded = get("never-existed").unwrap();
        assert!(loaded.last_run.is_some());
        assert!(loaded.created.is_none());
    }

    #[test]
    fn empty_meta_removes_entry() {
        let _g = setup();
        let now = chrono::Utc::now();
        set(
            "wf-1",
            WorkflowMeta {
                created: Some(now),
                ..Default::default()
            },
        );
        assert!(get("wf-1").is_some());

        set("wf-1", WorkflowMeta::default());
        assert!(get("wf-1").is_none());
    }

    #[test]
    fn remove_drops_entry() {
        let _g = setup();
        set(
            "wf-1",
            WorkflowMeta {
                created: Some(chrono::Utc::now()),
                ..Default::default()
            },
        );
        remove("wf-1");
        assert!(get("wf-1").is_none());
    }

    #[test]
    fn corrupt_file_backs_up_and_returns_default() {
        let _g = setup();
        let path = PathBuf::from(std::env::var("WFLOW_WORKFLOWS_META_PATH").unwrap());
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "this is not toml at all }}{{").unwrap();

        assert!(get("anything").is_none());
        // The broken file should be moved aside.
        assert!(!path.exists());
        let dir = path.parent().unwrap();
        let backups: Vec<_> = fs::read_dir(dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| {
                e.file_name()
                    .to_string_lossy()
                    .contains("workflows.toml.broken-")
            })
            .collect();
        assert_eq!(backups.len(), 1);
    }
}
