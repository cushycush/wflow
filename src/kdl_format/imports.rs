//! Cross-file imports: `imports { name "./path.kdl" }` + `use NAME`.
//!
//! Resolution happens at decode time. The decoder hands us a Workflow
//! whose step tree may contain `Action::Use { name }` nodes; we walk
//! the tree, splice the named fragment in place, and recurse. Cycles
//! are detected via a visited set of canonicalized paths.

use anyhow::{anyhow, bail, Context, Result};
use kdl::KdlDocument;

use crate::actions::{Action, Step, Workflow};

use super::decode::{decode, decode_step, suggest};

/// Parse a KDL file as authored — the imports map and any `use NAME`
/// step nodes are preserved exactly as written. Use this for editing
/// surfaces (the GUI editor) where the user wants to see, edit, and
/// round-trip the file's structure faithfully. The engine will not
/// dispatch `Action::Use` directly; callers that intend to run the
/// workflow should call `expand_imports_in_place` first.
pub fn decode_from_file_authored(path: &std::path::Path) -> Result<Workflow> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("read {}", path.display()))?;
    let wf = decode(&text).with_context(|| format!("parse {}", path.display()))?;
    Ok(wf)
}

/// Parse a KDL file and expand any `use NAME` nodes inside, resolving
/// each name through the workflow's `imports { ... }` block. Wraps
/// `decode` + `expand_imports`. Use this whenever the result is going
/// straight to the engine (CLI run, headless dispatch); use the
/// `_authored` variant when the result is going into an editor.
pub fn decode_from_file(path: &std::path::Path) -> Result<Workflow> {
    let mut wf = decode_from_file_authored(path)?;
    expand_imports_in_place(&mut wf, path)?;
    Ok(wf)
}

/// Expand `use NAME` references in `wf` against its imports map,
/// inlining the target fragments' steps. Also clears `wf.imports`
/// so re-encoding doesn't emit a now-redundant `imports {}` block.
/// `path` is the workflow file's location — used as the base dir
/// for resolving relative import paths and for cycle detection.
pub fn expand_imports_in_place(
    wf: &mut Workflow,
    path: &std::path::Path,
) -> Result<()> {
    let base_dir = path.parent().map(|p| p.to_path_buf()).unwrap_or_default();
    let mut visited = std::collections::HashSet::new();
    if let Ok(canon) = path.canonicalize() {
        visited.insert(canon);
    }
    let imports = wf.imports.clone();
    expand_imports(&mut wf.steps, &base_dir, &imports, &mut visited)?;
    wf.imports.clear();
    Ok(())
}

/// Decode a fragment file — a bare list of step nodes (no workflow
/// wrapper, no schema line). Returns the steps as authored, without
/// recursively expanding any `use` calls inside (a fragment viewed
/// standalone has no parent imports map to resolve against; the
/// caller is expected to render `use` cards as-is and let the user
/// navigate further by clicking them).
pub fn decode_fragment_file(path: &std::path::Path) -> Result<Vec<Step>> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("read {}", path.display()))?;
    let doc: KdlDocument = text
        .parse()
        .with_context(|| format!("parse {}", path.display()))?;
    let mut steps = Vec::new();
    for node in doc.nodes() {
        steps.push(
            decode_step(node)
                .with_context(|| format!("in fragment {}", path.display()))?,
        );
    }
    Ok(steps)
}

/// Walk a step list and splice every `Action::Use` with the decoded
/// top-level nodes of the target fragment file (looked up through the
/// workflow's imports map). Recurses into `repeat` / `when` / `unless`
/// blocks so nested uses resolve. Cycles are detected via a visited-set
/// of canonicalized paths; the current file is removed from the set
/// after its subtree is expanded so the same fragment can be used in
/// multiple sibling branches without false-positive cycle errors.
pub fn expand_imports(
    steps: &mut Vec<Step>,
    base_dir: &std::path::Path,
    imports: &std::collections::BTreeMap<String, String>,
    visited: &mut std::collections::HashSet<std::path::PathBuf>,
) -> Result<()> {
    let old = std::mem::take(steps);
    let mut expanded: Vec<Step> = Vec::with_capacity(old.len());
    for mut step in old {
        match step.action {
            Action::Use { name } => {
                let path = imports.get(&name).ok_or_else(|| {
                    let known: Vec<&str> = imports.keys().map(String::as_str).collect();
                    let hint = suggest(&name, &known)
                        .map(|s| format!(". did you mean `{s}`?"))
                        .unwrap_or_default();
                    let list = if known.is_empty() {
                        "(no imports declared — add `imports {{ name \"path\" }}` at the top of the file)".to_string()
                    } else {
                        format!("known: {}", known.join(", "))
                    };
                    anyhow!("unknown import `{name}`. {list}{hint}")
                })?;
                splice_fragment(path, base_dir, imports, visited, &mut expanded)?;
            }
            Action::Repeat { count, steps: mut inner } => {
                expand_imports(&mut inner, base_dir, imports, visited)?;
                step.action = Action::Repeat { count, steps: inner };
                expanded.push(step);
            }
            Action::Conditional { cond, negate, steps: mut inner, else_steps: mut inner_else } => {
                expand_imports(&mut inner, base_dir, imports, visited)?;
                expand_imports(&mut inner_else, base_dir, imports, visited)?;
                step.action = Action::Conditional {
                    cond,
                    negate,
                    steps: inner,
                    else_steps: inner_else,
                };
                expanded.push(step);
            }
            _ => expanded.push(step),
        }
    }
    *steps = expanded;
    Ok(())
}

/// Load a fragment file, decode its top-level nodes as steps, recurse
/// into further uses, and extend `out` with the result.
fn splice_fragment(
    path: &str,
    base_dir: &std::path::Path,
    imports: &std::collections::BTreeMap<String, String>,
    visited: &mut std::collections::HashSet<std::path::PathBuf>,
    out: &mut Vec<Step>,
) -> Result<()> {
    use std::collections::HashSet;
    let resolved = resolve_import_path(path, base_dir)?;
    if visited.contains(&resolved) {
        bail!(
            "import cycle detected: `{}` already in the import chain",
            resolved.display()
        );
    }
    let text = std::fs::read_to_string(&resolved)
        .with_context(|| format!("read import `{}`", resolved.display()))?;
    let doc: KdlDocument = text
        .parse()
        .with_context(|| format!("parse import `{}`", resolved.display()))?;
    let mut inner: Vec<Step> = Vec::new();
    for node in doc.nodes() {
        inner.push(
            decode_step(node)
                .with_context(|| format!("in import `{}`", resolved.display()))?,
        );
    }
    let inner_base = resolved
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| base_dir.to_path_buf());
    let mut nested_visited: HashSet<std::path::PathBuf> = visited.clone();
    nested_visited.insert(resolved.clone());
    expand_imports(&mut inner, &inner_base, imports, &mut nested_visited)?;
    out.extend(inner);
    Ok(())
}

pub fn resolve_import_path(
    path: &str,
    base_dir: &std::path::Path,
) -> Result<std::path::PathBuf> {
    // `~/` → $HOME.
    let expanded = if let Some(rest) = path.strip_prefix("~/") {
        match dirs::home_dir() {
            Some(h) => h.join(rest),
            None => bail!("can't expand `~/` — no home directory"),
        }
    } else if path == "~" {
        dirs::home_dir().ok_or_else(|| anyhow!("no home directory"))?
    } else {
        std::path::PathBuf::from(path)
    };
    let combined = if expanded.is_absolute() {
        expanded
    } else {
        base_dir.join(expanded)
    };
    combined
        .canonicalize()
        .with_context(|| format!("resolving import `{path}` relative to {}", base_dir.display()))
}
