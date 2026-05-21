//! Cross-file imports: `imports { name "./path.kdl" }` + `use NAME`.

use anyhow::{anyhow, bail, Context, Result};
use kdl::KdlDocument;

use crate::actions::{Action, Step, Workflow};

use super::decode::{decode, decode_step, suggest};

/// Parses a file with `use NAME` left in place. Editor uses this so
/// users can round-trip the file's structure as authored. Pair with
/// `expand_imports_in_place` before handing the workflow to the engine.
pub fn decode_from_file_authored(path: &std::path::Path) -> Result<Workflow> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("read {}", path.display()))?;
    let wf = decode(&text).with_context(|| format!("parse {}", path.display()))?;
    Ok(wf)
}

/// Parses a file and expands every `use NAME` against the imports map.
/// CLI run / headless dispatch path. Editor uses `_authored` instead.
pub fn decode_from_file(path: &std::path::Path) -> Result<Workflow> {
    let mut wf = decode_from_file_authored(path)?;
    expand_imports_in_place(&mut wf, path)?;
    Ok(wf)
}

/// Inline `use NAME` references; clear `wf.imports` so a re-encode
/// doesn't carry a now-redundant block. `path` resolves relative
/// import paths and seeds cycle detection.
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

/// Decode a bare list of step nodes (no workflow wrapper). Inner
/// `use` calls are left as-is, since a standalone fragment has no
/// parent imports map to resolve against.
pub fn decode_fragment_file(path: &std::path::Path) -> Result<Vec<Step>> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("read {}", path.display()))?;
    decode_fragment_str(&text)
        .with_context(|| format!("parse {}", path.display()))
}

/// String form of `decode_fragment_file`. Used by the editor for
/// clipboard paste so a chat snippet of bare step nodes round-trips
/// back into the canvas.
pub fn decode_fragment_str(text: &str) -> Result<Vec<Step>> {
    let doc: KdlDocument = text.parse().context("parse kdl fragment")?;
    let mut steps = Vec::new();
    for node in doc.nodes() {
        steps.push(decode_step(node).context("in kdl fragment")?);
    }
    Ok(steps)
}

/// Splice every `Action::Use` with the target fragment's decoded
/// top-level nodes. Recurses into repeat / when / unless. Visited
/// is per-branch so a fragment used twice in siblings is fine.
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
                        "(no imports declared, add `imports {{ name \"path\" }}` at the top of the file)".to_string()
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
            None => bail!("can't expand `~/`, no home directory"),
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
