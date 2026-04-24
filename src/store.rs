//! Workflow persistence.
//!
//! Workflows are stored as `.kdl` files at `$XDG_CONFIG_HOME/wflow/workflows/`.
//! For backward compatibility we also read `.json` files written by earlier
//! versions, and re-save them as KDL on the next write.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::actions::Workflow;
use crate::kdl_format;

fn workflows_dir() -> Result<PathBuf> {
    let base = dirs::config_dir().context("no XDG config dir")?;
    let dir = base.join("wflow").join("workflows");
    fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
    Ok(dir)
}

fn safe_id(id: &str) -> String {
    id.replace(['/', '\\', '.'], "_")
}

fn kdl_path_for(id: &str) -> Result<PathBuf> {
    Ok(workflows_dir()?.join(format!("{}.kdl", safe_id(id))))
}

fn legacy_json_path_for(id: &str) -> Result<PathBuf> {
    Ok(workflows_dir()?.join(format!("{}.json", safe_id(id))))
}

pub fn list() -> Result<Vec<Workflow>> {
    let dir = workflows_dir()?;
    let mut wfs: Vec<Workflow> = Vec::new();
    let mut seen_ids: std::collections::HashSet<String> = Default::default();
    for entry in fs::read_dir(&dir)? {
        let entry = entry?;
        let p = entry.path();
        match p.extension().and_then(|s| s.to_str()) {
            Some("kdl") | Some("json") => {}
            _ => continue,
        }
        match load_path(&p) {
            Ok(wf) => {
                if seen_ids.insert(wf.id.clone()) {
                    wfs.push(wf);
                }
            }
            Err(e) => tracing::warn!(?e, "skipping unreadable workflow {}", p.display()),
        }
    }
    wfs.sort_by(|a, b| {
        b.modified.unwrap_or_default().cmp(&a.modified.unwrap_or_default())
    });
    Ok(wfs)
}

pub fn load(id: &str) -> Result<Workflow> {
    let kdl = kdl_path_for(id)?;
    if kdl.exists() {
        return load_path(&kdl);
    }
    let json = legacy_json_path_for(id)?;
    if json.exists() {
        return load_path(&json);
    }
    anyhow::bail!("no workflow with id {id}")
}

fn load_path(p: &Path) -> Result<Workflow> {
    let bytes = fs::read(p).with_context(|| format!("read {}", p.display()))?;
    let s = String::from_utf8(bytes).with_context(|| format!("utf-8 {}", p.display()))?;
    if p.extension().and_then(|s| s.to_str()) == Some("json") {
        let wf: Workflow = serde_json::from_str(&s)
            .with_context(|| format!("parse json {}", p.display()))?;
        Ok(wf)
    } else {
        kdl_format::decode(&s).with_context(|| format!("parse kdl {}", p.display()))
    }
}

pub fn save(mut wf: Workflow) -> Result<Workflow> {
    wf.modified = Some(chrono::Utc::now());
    if wf.created.is_none() {
        wf.created = wf.modified;
    }

    let kdl_path = kdl_path_for(&wf.id)?;
    let tmp = kdl_path.with_extension("kdl.tmp");
    let text = kdl_format::encode(&wf);
    {
        let mut f = fs::File::create(&tmp)
            .with_context(|| format!("create {}", tmp.display()))?;
        f.write_all(text.as_bytes())?;
        f.sync_all().ok();
    }
    fs::rename(&tmp, &kdl_path)
        .with_context(|| format!("rename {} -> {}", tmp.display(), kdl_path.display()))?;

    // If a legacy JSON copy existed, retire it now.
    let json = legacy_json_path_for(&wf.id)?;
    if json.exists() {
        let _ = fs::remove_file(&json);
    }
    Ok(wf)
}

/// Filesystem path to the KDL file backing `id`, if it exists. Falls back
/// to the legacy `.json` file if no `.kdl` has been written yet. Returns
/// an error if neither exists.
pub fn path_of(id: &str) -> Result<PathBuf> {
    let kdl = kdl_path_for(id)?;
    if kdl.exists() {
        return Ok(kdl);
    }
    let json = legacy_json_path_for(id)?;
    if json.exists() {
        return Ok(json);
    }
    anyhow::bail!("no workflow with id {id}")
}

pub fn delete(id: &str) -> Result<()> {
    for p in [kdl_path_for(id)?, legacy_json_path_for(id)?] {
        if p.exists() {
            fs::remove_file(&p).with_context(|| format!("rm {}", p.display()))?;
        }
    }
    Ok(())
}

pub fn touch_last_run(id: &str) {
    let Ok(mut wf) = load(id) else { return };
    wf.last_run = Some(chrono::Utc::now());
    if let Err(e) = save(wf) {
        tracing::warn!(?e, "failed to touch last_run for {id}");
    }
}

// ---------- Import/export helpers used by commands ----------

pub fn export_kdl(id: &str) -> Result<String> {
    Ok(kdl_format::encode(&load(id)?))
}

/// Parse a KDL document and save it as a new workflow (new id minted).
/// Returns the saved workflow.
pub fn import_kdl(text: &str) -> Result<Workflow> {
    let mut wf = kdl_format::decode(text).context("the pasted recipe didn't parse")?;
    // Always mint a fresh id on import so sharing doesn't clobber the user's
    // own workflow with the same id.
    wf.id = uuid::Uuid::new_v4().to_string();
    wf.last_run = None;
    wf.created = None;
    wf.modified = None;
    save(wf)
}
