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
    if p.extension().and_then(|s| s.to_str()) == Some("json") {
        let bytes = fs::read(p).with_context(|| format!("read {}", p.display()))?;
        let s = String::from_utf8(bytes).with_context(|| format!("utf-8 {}", p.display()))?;
        let wf: Workflow = serde_json::from_str(&s)
            .with_context(|| format!("parse json {}", p.display()))?;
        return Ok(wf);
    }
    // KDL path: go through the include-expanding loader so
    // `include "other.kdl"` resolves relative to this file.
    let mut wf = kdl_format::decode_from_file(p)?;
    // The new format puts the id in the filename, not in the file.
    // The decoder leaves wf.id empty in that case; fill it from the
    // basename here. Legacy files still set id during decode and we
    // keep that one.
    if wf.id.is_empty() {
        if let Some(stem) = p.file_stem().and_then(|s| s.to_str()) {
            wf.id = stem.to_string();
        }
    }

    // Merge timestamps from the workflows.toml sidecar. Sidecar wins
    // for fields that are set in both (post-migration, the sidecar is
    // canonical). For fields the sidecar doesn't have but the file
    // does (legacy file, never been re-saved), the file value rides
    // through and the next save() writes it to the sidecar.
    if !wf.id.is_empty() {
        if let Some(meta) = crate::workflows_meta::get(&wf.id) {
            if meta.created.is_some() {
                wf.created = meta.created;
            }
            if meta.modified.is_some() {
                wf.modified = meta.modified;
            }
            if meta.last_run.is_some() {
                wf.last_run = meta.last_run;
            }
        }
    }

    Ok(wf)
}

pub fn save(mut wf: Workflow) -> Result<Workflow> {
    wf.modified = Some(chrono::Utc::now());
    if wf.created.is_none() {
        wf.created = wf.modified;
    }

    let kdl_path = kdl_path_for(&wf.id)?;
    let tmp = kdl_path.with_extension("kdl.tmp");

    // The encoder still writes timestamps inside the workflow block
    // for one transitional release (so a v0.4-built wflow can read a
    // freshly-saved file even before it learned about the sidecar).
    // Once the migration tool ships, the encoder stops emitting them.
    // For now we write them in BOTH places: file (on save) and
    // sidecar (canonical going forward). Legacy clients keep working;
    // new clients prefer sidecar.
    let text = kdl_format::encode(&wf);
    {
        let mut f = fs::File::create(&tmp)
            .with_context(|| format!("create {}", tmp.display()))?;
        f.write_all(text.as_bytes())?;
        f.sync_all().ok();
    }
    fs::rename(&tmp, &kdl_path)
        .with_context(|| format!("rename {} -> {}", tmp.display(), kdl_path.display()))?;

    // Persist the metadata to the sidecar as the canonical record.
    // Failures here are logged but don't block save — the file write
    // above is the durable artifact.
    // Preserve any existing positions on the entry — those are GUI
    // state, not workflow content, so they shouldn't be wiped just
    // because we're saving the workflow body.
    let existing = crate::workflows_meta::get(&wf.id).unwrap_or_default();
    crate::workflows_meta::set(
        &wf.id,
        crate::workflows_meta::WorkflowMeta {
            created: wf.created,
            modified: wf.modified,
            last_run: wf.last_run,
            card_positions: existing.card_positions,
        },
    );

    // If a legacy JSON copy existed, retire it now.
    let json = legacy_json_path_for(&wf.id)?;
    if json.exists() {
        let _ = fs::remove_file(&json);
    }

    // Auto-trust workflows wflow itself authored. The first-run prompt
    // is for files brought in from outside (downloaded, cloned, edited
    // by hand). Failures are best-effort — worst case the user gets an
    // extra prompt next run.
    crate::security::mark_trusted_from_disk(&kdl_path);

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
    // Drop the sidecar entry too. This isn't load-bearing — a stale
    // entry would just take up a few bytes in workflows.toml and get
    // ignored on lookup — but cleaning up keeps the file tidy.
    crate::workflows_meta::remove(id);
    Ok(())
}

pub fn touch_last_run(id: &str) {
    // Update the sidecar directly. We don't need to round-trip the
    // entire workflow through load + re-save just to bump a timestamp —
    // and going through save would also rewrite the .kdl file every
    // run, which is exactly the timestamp-churn the sidecar exists to
    // avoid.
    crate::workflows_meta::touch_last_run(id);
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
