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

pub fn workflows_dir() -> Result<PathBuf> {
    let base = dirs::config_dir().context("no XDG config dir")?;
    let dir = base.join("wflow").join("workflows");
    fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
    Ok(dir)
}

fn safe_id(id: &str) -> String {
    id.replace(['/', '\\', '.'], "_")
}

fn kdl_path_for(id: &str) -> Result<PathBuf> {
    kdl_path_for_in(id, None)
}

/// Return the .kdl path for a workflow id inside a specific folder.
/// folder=None ⇒ top-level (workflows_dir directly). folder=Some("a")
/// ⇒ workflows_dir/a/<safe_id>.kdl. Nested paths like "a/b" produce
/// workflows_dir/a/b/<safe_id>.kdl after sanitising each segment.
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

/// Sanitise a single user-supplied folder segment. Strips path
/// separators / colons / dots so it can't escape the workflows root
/// or accumulate dot-leakage like `..`.
fn safe_folder(s: &str) -> String {
    s.chars()
        .map(|c| if matches!(c, '/' | '\\' | ':' | '.') { '_' } else { c })
        .collect::<String>()
        .trim_matches('_')
        .to_string()
}

/// Sanitise a possibly-nested folder path like "a/b/c" into a list of
/// safe segments. Empty segments (consecutive slashes, leading slash)
/// are dropped; each segment passes through `safe_folder` so traversal
/// (`..`) and Windows-style paths (`\\`, `:`) are neutralised. The
/// joined path is guaranteed to stay inside the workflows root.
fn safe_folder_path_segments(s: &str) -> Vec<String> {
    s.split('/')
        .map(|seg| safe_folder(seg))
        .filter(|seg| !seg.is_empty())
        .collect()
}

/// Recursively walk the workflows directory and call `visit` for each
/// .kdl / .json file with its (path, folder-relative-to-root). Folder
/// names accumulate as forward-slash-joined paths — a workflow at
/// `<root>/a/b/wf.kdl` reports folder `Some("a/b")`. Top-level files
/// report `None`.
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
            // Skip:
            //   - empty / dotfile names
            //   - names starting with `_` (convention: private)
            //   - the conventional `lib` directory which holds
            //     `use NAME` fragment files (bare step lists, not
            //     full Workflow blocks). The walker would otherwise
            //     try to parse them as workflows and warn-skip every
            //     refresh.
            if sub_name.is_empty()
                || sub_name.starts_with('.')
                || sub_name.starts_with('_')
                || sub_name == "lib"
            {
                continue;
            }
            // Accumulate the parent folder path so nested
            // directories report their full relative location
            // (`a/b`) instead of just the leaf segment (`b`).
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
        // Library list only needs metadata (title, subtitle, step
        // count, etc.) — skip import expansion. Files with broken
        // `use` references still appear in the listing; the error
        // surfaces only when the user opens or runs them.
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

/// All folder paths currently present under the workflows root.
/// Includes empty subdirs (so a freshly-created folder shows up
/// before any workflow lives in it). Nested folders report their
/// full relative path: a directory at `<root>/a/b/` shows up as
/// `"a/b"`. Skips the same hidden / private / conventional `lib`
/// directories the walker skips.
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

/// mkdir a folder under the workflows root so it persists in the
/// library even before any workflow lives in it. Accepts nested
/// paths like `"a/b"` — each segment is sanitised independently and
/// the full chain is created with `fs::create_dir_all`.
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

/// Move a workflow's .kdl file into a different folder (or back to
/// top-level when `folder` is None / empty). Re-saves the workflow
/// at the new path and removes the old file.
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
    // KDL path. The `expand` flag selects whether to inline `use NAME`
    // references at load time (engine path) or preserve them so the
    // editor can show / round-trip the file as authored.
    let mut wf = if expand {
        kdl_format::decode_from_file(p)?
    } else {
        kdl_format::decode_from_file_authored(p)?
    };
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
            // Folder is canonicalised by the filesystem now, but
            // keep the meta entry in sync so any legacy reader sees
            // a consistent view.
            folder: wf.folder.clone(),
        },
    );

    // If a legacy JSON copy existed at the top-level, retire it.
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

/// Filesystem path to the KDL file backing `id`, if it exists. Walks
/// folder subdirectories. Returns an error if no file is found.
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

#[cfg(test)]
mod folder_path_tests {
    use super::*;

    #[test]
    fn nested_paths_segment_correctly() {
        assert_eq!(safe_folder_path_segments("a/b"), vec!["a", "b"]);
        assert_eq!(safe_folder_path_segments("a/b/c"), vec!["a", "b", "c"]);
        // Empty input → no segments.
        assert!(safe_folder_path_segments("").is_empty());
        // Leading / trailing slash → dropped empties.
        assert_eq!(safe_folder_path_segments("/a/"), vec!["a"]);
        assert_eq!(safe_folder_path_segments("a//b"), vec!["a", "b"]);
    }

    #[test]
    fn traversal_attempts_neutralised() {
        // `..` becomes `__` then trim → empty, dropped.
        assert!(safe_folder_path_segments("..").is_empty());
        assert_eq!(safe_folder_path_segments("../escape"), vec!["escape"]);
        assert_eq!(safe_folder_path_segments("a/../b"), vec!["a", "b"]);
        // Backslashes / colons collapse to `_` per character; the
        // pair `:\\` therefore becomes `__` mid-segment (we don't
        // collapse adjacent underscores — only trim them off the
        // ends).
        assert_eq!(
            safe_folder_path_segments("c:\\windows/sneaky"),
            vec!["c__windows", "sneaky"]
        );
    }
}

