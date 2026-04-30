//! Workflow persistence. `.kdl` at `$XDG_CONFIG_HOME/wflow/workflows/`
//! by default; user override comes through state.toml and is installed
//! via `set_workflows_dir_override`. Legacy `.json` files still read,
//! re-save as KDL.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::RwLock;

use anyhow::{Context, Result};

use crate::actions::Workflow;
use crate::kdl_format;

// `None` = XDG default. Populated at startup from state.toml.
static OVERRIDE: RwLock<Option<PathBuf>> = RwLock::new(None);

/// User override or the XDG default. Creates the dir if missing.
pub fn workflows_dir() -> Result<PathBuf> {
    if let Some(p) = OVERRIDE.read().ok().and_then(|g| g.clone()) {
        fs::create_dir_all(&p).with_context(|| format!("create {}", p.display()))?;
        return Ok(p);
    }
    default_workflows_dir()
}

/// XDG default, ignoring any override. For Settings display + tests.
pub fn default_workflows_dir() -> Result<PathBuf> {
    let base = dirs::config_dir().context("no XDG config dir")?;
    let dir = base.join("wflow").join("workflows");
    fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
    Ok(dir)
}

/// `None` reverts to the XDG default.
pub fn set_workflows_dir_override(path: Option<PathBuf>) {
    if let Ok(mut g) = OVERRIDE.write() {
        *g = path;
    }
}

/// Ok if the path is missing (we'll create it) or a writable
/// directory. Err carries a reason the UI can show.
pub fn validate_workflows_dir(path: &Path) -> Result<()> {
    if path.exists() {
        if !path.is_dir() {
            anyhow::bail!("path exists but isn't a directory");
        }
        let probe = path.join(".wflow-probe");
        match fs::write(&probe, b"") {
            Ok(()) => {
                let _ = fs::remove_file(&probe);
                Ok(())
            }
            Err(e) => anyhow::bail!("not writable: {e}"),
        }
    } else {
        // Refuse a typo like `~/Worflwos`.
        if let Some(parent) = path.parent() {
            if !parent.exists() {
                anyhow::bail!("parent directory does not exist: {}", parent.display());
            }
        }
        Ok(())
    }
}

fn safe_id(id: &str) -> String {
    id.replace(['/', '\\', '.'], "_")
}

fn kdl_path_for(id: &str) -> Result<PathBuf> {
    kdl_path_for_in(id, None)
}

/// Resolves `<workflows_dir>/<folder?>/<safe_id>.kdl`. Nested folders
/// like "a/b" sanitise per segment.
fn kdl_path_for_in(id: &str, folder: Option<&str>) -> Result<PathBuf> {
    let mut p = workflows_dir()?;
    if let Some(f) = folder {
        for seg in safe_folder_path_segments(f) {
            p.push(seg);
        }
    }
    p.push(format!("{}.kdl", safe_id(id)));
    Ok(p)
}

fn legacy_json_path_for(id: &str) -> Result<PathBuf> {
    Ok(workflows_dir()?.join(format!("{}.json", safe_id(id))))
}

/// Strips `/`, `\`, `:`, `.` so a segment can't escape the root.
fn safe_folder(s: &str) -> String {
    s.chars()
        .map(|c| if matches!(c, '/' | '\\' | ':' | '.') { '_' } else { c })
        .collect::<String>()
        .trim_matches('_')
        .to_string()
}

/// Splits "a/b/c" into a list of `safe_folder`-cleaned segments.
fn safe_folder_path_segments(s: &str) -> Vec<String> {
    s.split('/')
        .map(|seg| safe_folder(seg))
        .filter(|seg| !seg.is_empty())
        .collect()
}

/// Walks the workflows tree, calling `visit(path, folder)` per .kdl
/// / .json file. Folders join with `/`, top-level reports `None`.
fn walk_workflow_files<F: FnMut(&Path, Option<String>)>(
    dir: &Path,
    folder: Option<&str>,
    visit: &mut F,
) -> Result<()> {
    for entry in fs::read_dir(dir).with_context(|| format!("read_dir {}", dir.display()))? {
        let entry = entry?;
        let p = entry.path();
        let ft = entry.file_type()?;
        if ft.is_dir() {
            let sub_name = p
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string();
            // Skip dotfiles, `_*` (private convention), and `lib/`
            // (fragment files, not full workflows).
            if sub_name.is_empty()
                || sub_name.starts_with('.')
                || sub_name.starts_with('_')
                || sub_name == "lib"
            {
                continue;
            }
            let nested = match folder {
                Some(parent) if !parent.is_empty() => format!("{parent}/{sub_name}"),
                _ => sub_name.clone(),
            };
            walk_workflow_files(&p, Some(&nested), visit)?;
        } else {
            match p.extension().and_then(|s| s.to_str()) {
                Some("kdl") | Some("json") => visit(&p, folder.map(|s| s.to_string())),
                _ => {}
            }
        }
    }
    Ok(())
}

pub fn list() -> Result<Vec<Workflow>> {
    let dir = workflows_dir()?;
    let mut wfs: Vec<Workflow> = Vec::new();
    let mut seen_ids: std::collections::HashSet<String> = Default::default();
    walk_workflow_files(&dir, None, &mut |p, folder| {
        // Skip import expansion; broken `use` only surfaces at run time.
        match load_path(p, false) {
            Ok(mut wf) => {
                wf.folder = folder;
                if seen_ids.insert(wf.id.clone()) {
                    wfs.push(wf);
                }
            }
            Err(e) => tracing::warn!(?e, "skipping unreadable workflow {}", p.display()),
        }
    })?;
    wfs.sort_by(|a, b| {
        b.modified.unwrap_or_default().cmp(&a.modified.unwrap_or_default())
    });
    Ok(wfs)
}

/// Find the .kdl (or legacy .json) path for a workflow id by walking
/// the workflows tree. Returns None if not found.
fn find_path(id: &str) -> Result<Option<(PathBuf, Option<String>)>> {
    let dir = workflows_dir()?;
    let safe = safe_id(id);
    let target_kdl = format!("{}.kdl", safe);
    let target_json = format!("{}.json", safe);
    let mut found: Option<(PathBuf, Option<String>)> = None;
    walk_workflow_files(&dir, None, &mut |p, folder| {
        if found.is_some() { return; }
        if let Some(name) = p.file_name().and_then(|s| s.to_str()) {
            if name == target_kdl || name == target_json {
                found = Some((p.to_path_buf(), folder));
            }
        }
    })?;
    Ok(found)
}

pub fn load(id: &str) -> Result<Workflow> {
    load_with(id, /* expand_imports */ true)
}

/// Load a workflow with `use NAME` references and the imports map
/// preserved as authored. Use this for editing surfaces (the GUI);
/// the engine still wants the expanded form via `load`.
pub fn load_authored(id: &str) -> Result<Workflow> {
    load_with(id, /* expand_imports */ false)
}

fn load_with(id: &str, expand: bool) -> Result<Workflow> {
    if let Some((path, folder)) = find_path(id)? {
        let mut wf = load_path(&path, expand)?;
        wf.folder = folder;
        return Ok(wf);
    }
    anyhow::bail!("no workflow with id {id}")
}

/// All folder paths under the workflows root, including empty ones.
/// Nested directories report as "a/b". Same skip set as the walker.
pub fn list_folders() -> Result<Vec<String>> {
    let root = workflows_dir()?;
    let mut out: Vec<String> = Vec::new();
    if !root.exists() {
        return Ok(out);
    }
    list_folders_walk(&root, "", &mut out)?;
    out.sort();
    Ok(out)
}

fn list_folders_walk(dir: &Path, prefix: &str, out: &mut Vec<String>) -> Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let ft = entry.file_type()?;
        if !ft.is_dir() {
            continue;
        }
        let name = match entry.file_name().to_str() {
            Some(n) => n.to_string(),
            None => continue,
        };
        if name.is_empty()
            || name.starts_with('.')
            || name.starts_with('_')
            || name == "lib"
        {
            continue;
        }
        let nested = if prefix.is_empty() {
            name.clone()
        } else {
            format!("{prefix}/{name}")
        };
        out.push(nested.clone());
        list_folders_walk(&entry.path(), &nested, out)?;
    }
    Ok(())
}

/// Accepts nested paths like "a/b", each segment sanitised.
pub fn create_folder(name: &str) -> Result<()> {
    let segments = safe_folder_path_segments(name);
    if segments.is_empty() {
        anyhow::bail!("empty folder name");
    }
    let mut dir = workflows_dir()?;
    for seg in &segments {
        dir.push(seg);
    }
    fs::create_dir_all(&dir).with_context(|| format!("mkdir {}", dir.display()))?;
    Ok(())
}

/// `None` / empty `folder` moves the workflow back to top-level.
pub fn move_to_folder(id: &str, folder: Option<&str>) -> Result<()> {
    let (old_path, _old_folder) = match find_path(id)? {
        Some(p) => p,
        None => anyhow::bail!("no workflow with id {id}"),
    };
    let new_path = kdl_path_for_in(id, folder)?;
    if old_path == new_path { return Ok(()); }
    if let Some(parent) = new_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("mkdir {}", parent.display()))?;
    }
    fs::rename(&old_path, &new_path)
        .with_context(|| format!("mv {} -> {}", old_path.display(), new_path.display()))?;
    Ok(())
}

fn load_path(p: &Path, expand: bool) -> Result<Workflow> {
    if p.extension().and_then(|s| s.to_str()) == Some("json") {
        let bytes = fs::read(p).with_context(|| format!("read {}", p.display()))?;
        let s = String::from_utf8(bytes).with_context(|| format!("utf-8 {}", p.display()))?;
        let wf: Workflow = serde_json::from_str(&s)
            .with_context(|| format!("parse json {}", p.display()))?;
        return Ok(wf);
    }
    // `expand` = inline `use NAME` (engine path) vs preserve (editor).
    let mut wf = if expand {
        kdl_format::decode_from_file(p)?
    } else {
        kdl_format::decode_from_file_authored(p)?
    };
    // New format: id comes from the filename.
    if wf.id.is_empty() {
        if let Some(stem) = p.file_stem().and_then(|s| s.to_str()) {
            wf.id = stem.to_string();
        }
    }

    // Sidecar wins; legacy file values ride through if the sidecar
    // doesn't carry them yet (next save() will).
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

    // Resolve the folder. Priority: wf.folder if explicitly set on
    // the in-memory struct → otherwise look up the existing file's
    // location so save-without-move keeps the workflow where it was.
    let folder = wf.folder.clone().or_else(|| {
        find_path(&wf.id).ok().flatten().and_then(|(_, f)| f)
    });
    wf.folder = folder.clone();

    let kdl_path = kdl_path_for_in(&wf.id, folder.as_deref())?;
    if let Some(parent) = kdl_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("mkdir {}", parent.display()))?;
    }
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

    // Sidecar is canonical. Preserve card_positions (GUI state).
    let existing = crate::workflows_meta::get(&wf.id).unwrap_or_default();
    crate::workflows_meta::set(
        &wf.id,
        crate::workflows_meta::WorkflowMeta {
            created: wf.created,
            modified: wf.modified,
            last_run: wf.last_run,
            card_positions: existing.card_positions,
            folder: wf.folder.clone(),
        },
    );

    // If a legacy JSON copy existed at the top-level, retire it.
    let json = legacy_json_path_for(&wf.id)?;
    if json.exists() {
        let _ = fs::remove_file(&json);
    }

    // Auto-trust files wflow itself wrote. The first-run prompt is
    // for files brought in from outside.
    crate::security::mark_trusted_from_disk(&kdl_path);

    Ok(wf)
}

pub fn path_of(id: &str) -> Result<PathBuf> {
    if let Some((p, _)) = find_path(id)? {
        return Ok(p);
    }
    anyhow::bail!("no workflow with id {id}")
}

pub fn delete(id: &str) -> Result<()> {
    if let Some((p, _)) = find_path(id)? {
        fs::remove_file(&p).with_context(|| format!("rm {}", p.display()))?;
    }
    // Drop the sidecar entry too.
    crate::workflows_meta::remove(id);
    Ok(())
}

pub fn touch_last_run(id: &str) {
    // Sidecar-only; saving the .kdl per run was the churn we left behind.
    crate::workflows_meta::touch_last_run(id);
}

// Import/export helpers.

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

#[cfg(test)]
mod folder_path_tests {
    use super::*;

    #[test]
    fn nested_paths_segment_correctly() {
        assert_eq!(safe_folder_path_segments("a/b"), vec!["a", "b"]);
        assert_eq!(safe_folder_path_segments("a/b/c"), vec!["a", "b", "c"]);
        assert!(safe_folder_path_segments("").is_empty());
        assert_eq!(safe_folder_path_segments("/a/"), vec!["a"]);
        assert_eq!(safe_folder_path_segments("a//b"), vec!["a", "b"]);
    }

    #[test]
    fn traversal_attempts_neutralised() {
        // `..` → `__`, trim, drop.
        assert!(safe_folder_path_segments("..").is_empty());
        assert_eq!(safe_folder_path_segments("../escape"), vec!["escape"]);
        assert_eq!(safe_folder_path_segments("a/../b"), vec!["a", "b"]);
        assert_eq!(
            safe_folder_path_segments("c:\\windows/sneaky"),
            vec!["c__windows", "sneaky"]
        );
    }
}

