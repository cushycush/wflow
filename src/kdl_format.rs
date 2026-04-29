//! KDL encoder/decoder for Workflow.
//!
//! The goal here is not round-trip-preserving edits — yet — but to emit KDL
//! that reads naturally to a human and parses back into a clean `Workflow`.
//! Format:
//!
//! ```kdl
//! schema 1
//! id "uuid"
//! title "Open my dev setup"
//! subtitle "launch editor, terminal, focus browser"
//! created "2026-04-22T12:30:00Z"
//!
//! recipe {
//!     type "hello, world" delay-ms=30
//!     wait 500
//!     key "ctrl+shift+p"
//!     shell "hyprctl dispatch exec firefox"
//!     note "enable the VPN manually"
//!     key "Return" disabled=#true comment="commented out for now"
//! }
//! ```
//!
//! Step-level metadata (`disabled=`, `comment=`) may appear on any action
//! node. Integer values are accepted as both bare args and named props
//! (`wait 500` or `wait ms=500`) where sensible.

use anyhow::{anyhow, bail, Context, Result};
use kdl::{KdlDocument, KdlEntry, KdlIdentifier, KdlNode, KdlValue};

use crate::actions::{normalize_chord, Action, Condition, OnError, Step, Workflow};

pub const SCHEMA_VERSION: i128 = 1;

// ---------------------------------------------------------- Encoding --------

/// Emit a workflow as KDL. Always uses the v0.4 `workflow "title" { ... }`
/// shape — legacy files round-trip into this form on first save.
///
/// `id` is no longer in the file; the filename is the id. Timestamps
/// (`created` / `modified` / `last-run`) still ride along inside the
/// block for now and move to a sidecar in a follow-up commit, at which
/// point this function stops emitting them. Decoder keeps reading them
/// regardless so old files don't break.
pub fn encode(wf: &Workflow) -> String {
    let mut doc = KdlDocument::new();

    let mut wf_node = KdlNode::new("workflow");
    wf_node.push(arg_str(&wf.title));

    let mut inner = KdlDocument::new();

    if let Some(s) = &wf.subtitle {
        if !s.is_empty() {
            inner.nodes_mut().push(kv_str("subtitle", s));
        }
    }
    // Timestamps (`created` / `modified` / `last_run`) live in the
    // workflows.toml sidecar now; the encoder no longer touches them.
    // Decoder still reads them from legacy / pre-migration files so
    // those keep parsing.

    // Variables block — emitted only when present so empty files stay tidy.
    if !wf.vars.is_empty() {
        let mut vars_node = KdlNode::new("vars");
        let mut vars_inner = KdlDocument::new();
        for (k, v) in &wf.vars {
            vars_inner.nodes_mut().push(kv_str(k, v));
        }
        vars_node.set_children(vars_inner);
        inner.nodes_mut().push(vars_node);
    }

    // Imports block — same emit-only-if-present rule.
    if !wf.imports.is_empty() {
        let mut imports_node = KdlNode::new("imports");
        let mut imports_inner = KdlDocument::new();
        for (k, v) in &wf.imports {
            imports_inner.nodes_mut().push(kv_str(k, v));
        }
        imports_node.set_children(imports_inner);
        inner.nodes_mut().push(imports_node);
    }

    // Triggers — emitted before steps so the binding is the first
    // thing a reader sees when scanning a workflow file.
    for trigger in &wf.triggers {
        inner.nodes_mut().push(encode_trigger(trigger));
    }

    // Step nodes are direct children of the workflow block; no more
    // `recipe { }` wrapper.
    for step in &wf.steps {
        inner.nodes_mut().push(encode_step(step));
    }

    // Visual-grouping rectangles. Decorative — engine ignores them
    // — but they live alongside steps in the file so the canvas
    // layout survives a reload.
    if !wf.groups.is_empty() {
        let mut groups_node = KdlNode::new("groups");
        let mut groups_inner = KdlDocument::new();
        for g in &wf.groups {
            groups_inner.nodes_mut().push(encode_group(g));
        }
        groups_node.set_children(groups_inner);
        inner.nodes_mut().push(groups_node);
    }

    wf_node.set_children(inner);
    doc.nodes_mut().push(wf_node);

    doc.autoformat();
    doc.to_string()
}

fn encode_group(g: &crate::actions::Group) -> KdlNode {
    let mut node = KdlNode::new("group");
    // Comment is the positional argument (mirrors how `note "text"`
    // works) so the file still reads naturally for human authors.
    node.push(arg_str(&g.comment));
    node.push(prop_str("id", &g.id));
    node.entries_mut().push(kdl::KdlEntry::new_prop("x", g.x));
    node.entries_mut().push(kdl::KdlEntry::new_prop("y", g.y));
    node.entries_mut().push(kdl::KdlEntry::new_prop("width", g.width));
    node.entries_mut().push(kdl::KdlEntry::new_prop("height", g.height));
    node.push(prop_str("color", &g.color));
    node
}

fn encode_trigger(trigger: &crate::actions::Trigger) -> KdlNode {
    use crate::actions::{TriggerCondition, TriggerKind};
    let mut node = KdlNode::new("trigger");
    let mut inner = KdlDocument::new();
    match &trigger.kind {
        TriggerKind::Chord { chord } => {
            inner.nodes_mut().push(kv_str("chord", chord));
        }
        TriggerKind::Hotstring { text } => {
            inner.nodes_mut().push(kv_str("hotstring", text));
        }
    }
    if let Some(cond) = &trigger.when {
        let mut when = KdlNode::new("when");
        match cond {
            TriggerCondition::WindowClass { class } => {
                when.push(prop_str("window-class", class));
            }
            TriggerCondition::WindowTitle { title } => {
                when.push(prop_str("window-title", title));
            }
        }
        inner.nodes_mut().push(when);
    }
    node.set_children(inner);
    node
}

/// Encode a list of steps as a bare KDL fragment — the format used
/// by the `use NAME` import targets. No `workflow` wrapper, no
/// schema, no title or imports map; just the step nodes one after
/// another. Mirrors the parser side (`decode_fragment_file`).
pub fn encode_fragment(steps: &[Step]) -> String {
    let mut doc = KdlDocument::new();
    for step in steps {
        doc.nodes_mut().push(encode_step(step));
    }
    doc.to_string()
}

fn encode_step(step: &Step) -> KdlNode {
    let mut node = match &step.action {
        Action::WdoType { text, delay_ms } => {
            let mut n = KdlNode::new("type");
            n.push(arg_str(text));
            if let Some(d) = delay_ms {
                n.push(prop_int("delay-ms", *d as i128));
            }
            n
        }
        Action::WdoKey {
            chord,
            clear_modifiers,
        } => {
            let mut n = KdlNode::new("key");
            n.push(arg_str(chord));
            if *clear_modifiers {
                n.push(prop_bool("clear-modifiers", true));
            }
            n
        }
        Action::WdoKeyDown { chord } => {
            let mut n = KdlNode::new("key-down");
            n.push(arg_str(chord));
            n
        }
        Action::WdoKeyUp { chord } => {
            let mut n = KdlNode::new("key-up");
            n.push(arg_str(chord));
            n
        }
        Action::WdoClick { button } => {
            let mut n = KdlNode::new("click");
            n.push(arg_int(*button as i128));
            n
        }
        Action::WdoMouseDown { button } => {
            let mut n = KdlNode::new("mouse-down");
            n.push(arg_int(*button as i128));
            n
        }
        Action::WdoMouseUp { button } => {
            let mut n = KdlNode::new("mouse-up");
            n.push(arg_int(*button as i128));
            n
        }
        Action::WdoMouseMove { x, y, relative } => {
            let mut n = KdlNode::new("move");
            n.push(arg_int(*x as i128));
            n.push(arg_int(*y as i128));
            if *relative {
                n.push(prop_bool("relative", true));
            }
            n
        }
        Action::WdoScroll { dx, dy } => {
            let mut n = KdlNode::new("scroll");
            n.push(arg_int(*dx as i128));
            n.push(arg_int(*dy as i128));
            n
        }
        Action::WdoActivateWindow { name } => {
            let mut n = KdlNode::new("focus");
            n.push(arg_str(name));
            n
        }
        Action::WdoAwaitWindow { name, timeout_ms } => {
            let mut n = KdlNode::new("wait-window");
            n.push(arg_str(name));
            // Emit the timeout as an integer (ms) for round-trip stability;
            // users can hand-write `timeout="5s"` and we'll parse both.
            n.push(prop_int("timeout-ms", *timeout_ms as i128));
            n
        }
        Action::Delay { ms } => {
            let mut n = KdlNode::new("wait");
            n.push(arg_int(*ms as i128));
            n
        }
        Action::Shell {
            command,
            shell,
            capture_as,
            timeout_ms,
            retries,
            backoff_ms,
        } => {
            let mut n = KdlNode::new("shell");
            n.push(arg_str(command));
            if let Some(s) = shell {
                n.push(prop_str("with", s));
            }
            if let Some(name) = capture_as {
                n.push(prop_str("as", name));
            }
            if let Some(ms) = timeout_ms {
                n.push(prop_int("timeout-ms", *ms as i128));
            }
            if *retries > 0 {
                n.push(prop_int("retries", *retries as i128));
            }
            if let Some(ms) = backoff_ms {
                n.push(prop_int("backoff-ms", *ms as i128));
            }
            n
        }
        Action::Notify { title, body } => {
            let mut n = KdlNode::new("notify");
            n.push(arg_str(title));
            if let Some(b) = body {
                n.push(prop_str("body", b));
            }
            n
        }
        Action::Clipboard { text } => {
            let mut n = KdlNode::new("clipboard");
            n.push(arg_str(text));
            n
        }
        Action::Note { text } => {
            let mut n = KdlNode::new("note");
            n.push(arg_str(text));
            n
        }
        Action::Repeat { count, steps } => {
            let mut n = KdlNode::new("repeat");
            n.push(arg_int(*count as i128));
            let mut inner = KdlDocument::new();
            for step in steps {
                inner.nodes_mut().push(encode_step(step));
            }
            n.set_children(inner);
            n
        }
        Action::Use { name } => {
            let mut n = KdlNode::new("use");
            n.push(arg_str(name));
            n
        }
        Action::Conditional { cond, negate, steps } => {
            let mut n = KdlNode::new(if *negate { "unless" } else { "when" });
            match cond {
                Condition::Window { name } => n.push(prop_str("window", name)),
                Condition::File { path } => n.push(prop_str("file", path)),
                Condition::Env { name, equals } => {
                    n.push(prop_str("env", name));
                    if let Some(v) = equals {
                        n.push(prop_str("equals", v));
                    }
                }
            }
            let mut inner = KdlDocument::new();
            for step in steps {
                inner.nodes_mut().push(encode_step(step));
            }
            n.set_children(inner);
            n
        }
    };

    // Step-level metadata on any action node.
    if !step.enabled {
        node.push(prop_bool("disabled", true));
    }
    if let Some(c) = &step.note {
        if !c.is_empty() {
            node.push(prop_str("comment", c));
        }
    }
    if step.on_error != OnError::Stop {
        let v = match step.on_error {
            OnError::Continue => "continue",
            OnError::Stop => "stop", // never emitted (default)
        };
        node.push(prop_str("on-error", v));
    }
    // Stable step id. Emitted with a leading underscore so it reads
    // as "internal metadata" alongside `disabled` / `comment` /
    // `on-error`. The id round-trips through encode/decode so GUI
    // features keyed on step.id (canvas card positions, comments,
    // future per-step state) survive `wflow edit` and any other
    // save-and-reload cycle.
    if !step.id.is_empty() {
        node.push(prop_str("_id", &step.id));
    }
    node
}

fn arg_str(s: &str) -> KdlEntry { KdlEntry::new(KdlValue::String(s.into())) }
fn arg_int(v: i128) -> KdlEntry { KdlEntry::new(KdlValue::Integer(v)) }
fn prop_str(k: &str, v: &str) -> KdlEntry {
    let mut e = KdlEntry::new(KdlValue::String(v.into()));
    e.set_name(Some(KdlIdentifier::from(k)));
    e
}
fn prop_int(k: &str, v: i128) -> KdlEntry {
    let mut e = KdlEntry::new(KdlValue::Integer(v));
    e.set_name(Some(KdlIdentifier::from(k)));
    e
}
fn prop_bool(k: &str, v: bool) -> KdlEntry {
    let mut e = KdlEntry::new(KdlValue::Bool(v));
    e.set_name(Some(KdlIdentifier::from(k)));
    e
}
fn kv_str(name: &str, v: &str) -> KdlNode {
    let mut n = KdlNode::new(name);
    n.push(arg_str(v));
    n
}
fn kv_int(name: &str, v: i128) -> KdlNode {
    let mut n = KdlNode::new(name);
    n.push(arg_int(v));
    n
}

// ---------------------------------------------------------- Decoding --------

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
            Action::Conditional { cond, negate, steps: mut inner } => {
                expand_imports(&mut inner, base_dir, imports, visited)?;
                step.action = Action::Conditional { cond, negate, steps: inner };
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

/// Top-level decode. Detects which file format we're reading and
/// dispatches. Two shapes are accepted:
///
/// - **New** (default since v0.4):
///   ```kdl
///   workflow "Open dev setup" {
///       subtitle "..."
///       vars { ... }
///       shell "..."
///       ...
///   }
///   ```
///
/// - **Legacy** (everything before v0.4):
///   ```kdl
///   schema 1
///   id "..."
///   title "..."
///   recipe { ... }
///   ```
///
/// Files in the legacy format keep parsing forever. The encoder emits
/// the new shape, so legacy files round-trip into the new shape on the
/// next save. `wflow migrate` does the conversion explicitly for users
/// who don't want to wait for the GUI editor's lazy migration.
pub fn decode(src: &str) -> Result<Workflow> {
    let doc: KdlDocument = src.parse().context("parsing KDL")?;

    let workflow_nodes: Vec<&KdlNode> = doc
        .nodes()
        .iter()
        .filter(|n| n.name().value() == "workflow")
        .collect();

    let mixed = !workflow_nodes.is_empty()
        && doc.nodes().iter().any(|n| {
            matches!(
                n.name().value(),
                "schema"
                    | "id"
                    | "title"
                    | "subtitle"
                    | "created"
                    | "modified"
                    | "last-run"
                    | "vars"
                    | "imports"
                    | "recipe"
            )
        });
    if mixed {
        bail!(
            "file mixes the legacy top-level layout (`schema 1`, `id`, `title`, `recipe`) \
             with a `workflow {{ ... }}` block. Pick one format. \
             Run `wflow migrate` to convert legacy files in place."
        );
    }

    if workflow_nodes.len() > 1 {
        bail!(
            "file has {} `workflow` blocks. Multiple workflows per file is reserved for a \
             future release; for now, one workflow per file",
            workflow_nodes.len()
        );
    }

    if workflow_nodes.len() == 1 {
        decode_workflow_block(workflow_nodes[0])
    } else {
        decode_legacy(&doc)
    }
}

/// New-format decoder: a single root `workflow "title" { ... }` node.
/// `id` is intentionally NOT set here — the caller fills it from the
/// filename. (For `wflow run <path>` against a hand-written file the
/// id stays empty, which is fine since we never write back.)
fn decode_workflow_block(wf_node: &KdlNode) -> Result<Workflow> {
    let title = first_string(wf_node).with_context(|| {
        "`workflow \"...\"` needs a title in quotes (e.g. `workflow \"Morning standup\" { ... }`)"
            .to_string()
    })?;
    // The workflow node itself takes no properties today.
    validate_props(wf_node, "workflow", &[])?;

    let children = wf_node.children().ok_or_else(|| {
        anyhow!(
            "`workflow {:?}` must have a {{ ... }} body containing the steps and any `subtitle` / \
             `vars` / `imports` blocks",
            title
        )
    })?;

    let mut subtitle: Option<String> = None;
    let mut created = None;
    let mut modified = None;
    let mut last_run = None;
    let mut vars: std::collections::BTreeMap<String, String> = Default::default();
    let mut imports: std::collections::BTreeMap<String, String> = Default::default();
    let mut steps: Vec<Step> = Vec::new();
    let mut triggers: Vec<crate::actions::Trigger> = Vec::new();
    let mut groups: Vec<crate::actions::Group> = Vec::new();
    let mut subtitle_seen = false;

    for node in children.nodes() {
        match node.name().value() {
            "trigger" => triggers.push(decode_trigger(node)?),
            "subtitle" => {
                if subtitle_seen {
                    bail!("`subtitle` appears twice; one per workflow");
                }
                subtitle_seen = true;
                subtitle = Some(first_string(node)?);
            }
            // Timestamps are accepted as children for the brief window
            // between the format change and the metadata-sidecar move,
            // and to support legacy files that the migrator hasn't
            // touched yet. Once `wflow migrate` runs and the encoder
            // strips them, they don't reappear.
            "created" => created = parse_ts_opt(&first_string(node)?),
            "modified" => modified = parse_ts_opt(&first_string(node)?),
            "last-run" => last_run = parse_ts_opt(&first_string(node)?),
            "vars" => {
                let inner = node
                    .children()
                    .ok_or_else(|| anyhow!("`vars` must have a block {{ ... }}"))?;
                for var_node in inner.nodes() {
                    let key = var_node.name().value().to_string();
                    if key.starts_with("env.") {
                        bail!(
                            "`vars` can't define `{key}` — the `env.*` namespace is reserved \
                             for process environment lookups"
                        );
                    }
                    let value = first_string(var_node).with_context(|| {
                        format!("`vars {{ {key} ... }}` needs a string value")
                    })?;
                    vars.insert(key, value);
                }
            }
            "imports" => {
                let inner = node
                    .children()
                    .ok_or_else(|| anyhow!("`imports` must have a block {{ ... }}"))?;
                for imp_node in inner.nodes() {
                    let key = imp_node.name().value().to_string();
                    let path = first_string(imp_node).with_context(|| {
                        format!("`imports {{ {key} ... }}` needs a path string")
                    })?;
                    if imports.contains_key(&key) {
                        bail!("duplicate import name `{key}`");
                    }
                    imports.insert(key, path);
                }
            }
            "groups" => {
                let inner = node
                    .children()
                    .ok_or_else(|| anyhow!("`groups` must have a block {{ ... }}"))?;
                for grp_node in inner.nodes() {
                    if grp_node.name().value() != "group" {
                        bail!(
                            "unexpected `{}` inside `groups {{ ... }}` — only \
                             `group` nodes belong here",
                            grp_node.name().value()
                        );
                    }
                    groups.push(decode_group(grp_node)?);
                }
            }
            // Reserved guard: `id` and `title` and `recipe` are legacy
            // top-level fields and don't make sense inside the workflow
            // block. Reject loudly so a half-migrated file gets flagged.
            "id" => bail!(
                "`id` doesn't belong inside a `workflow` block — \
                 the filename is the id in the new format"
            ),
            "title" => bail!(
                "`title` doesn't belong inside a `workflow` block — \
                 it's the positional arg of `workflow \"...\"`"
            ),
            "recipe" => bail!(
                "`recipe {{ ... }}` is the legacy block name. In the new format, \
                 step nodes are direct children of the `workflow` block — drop the `recipe` wrapper."
            ),
            "schema" => bail!(
                "`schema` is no longer a per-file field. The format version is implicit \
                 in the document shape"
            ),
            // Anything else is a step verb. decode_step validates it.
            _ => steps.push(decode_step(node)?),
        }
    }

    Ok(Workflow {
        id: String::new(),
        title,
        subtitle,
        steps,
        vars,
        imports,
        triggers,
        groups,
        created,
        modified,
        last_run,
        folder: None,
    })
}

fn decode_group(node: &KdlNode) -> Result<crate::actions::Group> {
    use crate::actions::Group;
    // The first positional string is the comment text — same shape
    // as `note "text"`. Properties carry id, x, y, width, height,
    // color.
    let comment = first_string(node).unwrap_or_default();
    let id = node
        .get("id")
        .and_then(|v| v.as_string().map(str::to_string))
        .unwrap_or_else(|| {
            // Generate one if missing — old hand-edited files might
            // omit this and we'd rather render the group than reject
            // the workflow.
            uuid::Uuid::new_v4().to_string()
        });
    let x = node
        .get("x")
        .and_then(|v| v.as_float())
        .unwrap_or(0.0);
    let y = node
        .get("y")
        .and_then(|v| v.as_float())
        .unwrap_or(0.0);
    let width = node
        .get("width")
        .and_then(|v| v.as_float())
        .unwrap_or(200.0);
    let height = node
        .get("height")
        .and_then(|v| v.as_float())
        .unwrap_or(120.0);
    let color = node
        .get("color")
        .and_then(|v| v.as_string().map(str::to_string))
        .unwrap_or_else(|| "accent".to_string());
    Ok(Group { id, x, y, width, height, color, comment })
}

/// Legacy-format decoder: `schema 1`, top-level `id` / `title` /
/// `subtitle` / etc., and a `recipe { ... }` block. Kept verbatim so
/// older files keep parsing.
fn decode_legacy(doc: &KdlDocument) -> Result<Workflow> {
    let mut id: Option<String> = None;
    let mut title: Option<String> = None;
    let mut subtitle: Option<String> = None;
    let mut created = None;
    let mut modified = None;
    let mut last_run = None;
    let mut steps: Vec<Step> = Vec::new();
    let mut vars: std::collections::BTreeMap<String, String> = Default::default();
    let mut imports: std::collections::BTreeMap<String, String> = Default::default();
    let mut recipe_seen = false;

    for node in doc.nodes() {
        match node.name().value() {
            "schema" => {
                // Reject unknown schema versions rather than silently
                // running a file meant for a newer wflow. `schema 1` is
                // the only accepted value today.
                let v = first_int_opt(node)
                    .ok_or_else(|| anyhow!("`schema` needs an integer (try `schema 1`)"))?;
                if v != SCHEMA_VERSION {
                    bail!(
                        "schema {v} is not supported (this wflow reads schema {SCHEMA_VERSION}). \
                         upgrade wflow or convert the file"
                    );
                }
            }
            "id" => id = Some(first_string(node)?),
            "title" => title = Some(first_string(node)?),
            "subtitle" => subtitle = Some(first_string(node)?),
            "created" => created = parse_ts_opt(&first_string(node)?),
            "modified" => modified = parse_ts_opt(&first_string(node)?),
            "last-run" => last_run = parse_ts_opt(&first_string(node)?),
            "vars" => {
                // `vars { name "value" ... }` — workflow-level bindings
                // that actions can substitute as `{{name}}` at run time.
                let children = node
                    .children()
                    .ok_or_else(|| anyhow!("`vars` must have a block {{ ... }}"))?;
                for var_node in children.nodes() {
                    let key = var_node.name().value().to_string();
                    if key.starts_with("env.") {
                        bail!(
                            "`vars` can't define `{key}` — the `env.*` namespace is reserved \
                             for process environment lookups"
                        );
                    }
                    let value = first_string(var_node).with_context(|| {
                        format!("`vars {{ {key} ... }}` needs a string value")
                    })?;
                    vars.insert(key, value);
                }
            }
            "imports" => {
                // `imports { name "path" ... }` — named references to
                // fragment files, splice-able as `use name` inside recipe
                // (or any nested block).
                let children = node
                    .children()
                    .ok_or_else(|| anyhow!("`imports` must have a block {{ ... }}"))?;
                for imp_node in children.nodes() {
                    let key = imp_node.name().value().to_string();
                    let path = first_string(imp_node).with_context(|| {
                        format!("`imports {{ {key} ... }}` needs a path string")
                    })?;
                    if imports.contains_key(&key) {
                        bail!("duplicate import name `{key}`");
                    }
                    imports.insert(key, path);
                }
            }
            "recipe" => {
                recipe_seen = true;
                let children = node
                    .children()
                    .ok_or_else(|| anyhow!("`recipe` must have a block {{ ... }}"))?;
                for step_node in children.nodes() {
                    steps.push(decode_step(step_node)?);
                }
            }
            other => {
                // An unknown top-level node is almost always a typo — say
                // so loudly instead of dropping it silently.
                let valid = [
                    "schema", "id", "title", "subtitle", "created",
                    "modified", "last-run", "vars", "imports", "recipe",
                ];
                let hint = suggest(other, &valid)
                    .map(|s| format!(". did you mean `{s}`?"))
                    .unwrap_or_default();
                bail!(
                    "unknown top-level node `{other}`. valid: {}{hint}",
                    valid.join(", ")
                );
            }
        }
    }

    // Required fields: id, title, recipe. `subtitle` and timestamps stay
    // optional. Missing `recipe` was previously a silent empty workflow.
    let id = id.ok_or_else(|| {
        anyhow!("missing required `id \"...\"` at the top of the file (e.g. `id \"morning-setup\"`)")
    })?;
    let title = title.ok_or_else(|| {
        anyhow!("missing required `title \"...\"` at the top of the file")
    })?;
    if !recipe_seen {
        bail!("missing required `recipe {{ ... }}` block");
    }

    Ok(Workflow {
        id,
        title,
        subtitle,
        steps,
        vars,
        imports,
        triggers: Vec::new(),
        groups: Vec::new(),
        created,
        modified,
        last_run,
        folder: None,
    })
}

fn decode_step(node: &KdlNode) -> Result<Step> {
    let raw_name = node.name().value();
    let name = canonical_verb(raw_name);

    // Reject unknown props up-front. Every action accepts `disabled` and
    // `comment` on top of its own list. A typo'd `retries=3` or `wndow=...`
    // now hard-errors instead of being silently dropped.
    validate_props(node, name, action_props(name))?;

    // Pull step-level metadata off first, so the action decoders don't see them.
    let disabled = prop_bool_or(node, "disabled", false);
    let comment = prop_string(node, "comment");
    let on_error = match prop_string(node, "on-error").as_deref() {
        None => OnError::Stop,
        Some("stop") => OnError::Stop,
        Some("continue") => OnError::Continue,
        Some(other) => bail!(
            "`on-error` must be \"stop\" or \"continue\", got `{other}`"
        ),
    };

    let action: Action = match name {
        "type" => {
            let text = first_string(node)?;
            let delay_ms = prop_integer(node,"delay-ms").map(|n| n as u32);
            Action::WdoType { text, delay_ms }
        }
        "key" => {
            let chord = normalize_chord(&first_string(node)?);
            let clear_modifiers = prop_bool_or(node, "clear-modifiers", false);
            Action::WdoKey {
                chord,
                clear_modifiers,
            }
        }
        "click" => {
            // click 1  |  click button=1  |  click (defaults to 1)
            let positional = first_int_opt(node);
            let prop = prop_integer(node, "button");
            let button = match (positional, prop) {
                (Some(_), Some(_)) => bail!(
                    "`click`: specify the button as `click 1` or `click button=1`, not both"
                ),
                (Some(p), None) | (None, Some(p)) => p as u8,
                (None, None) => 1,
            };
            Action::WdoClick { button }
        }
        "key-down" => Action::WdoKeyDown { chord: normalize_chord(&first_string(node)?) },
        "key-up" => Action::WdoKeyUp { chord: normalize_chord(&first_string(node)?) },
        "mouse-down" => {
            let button = first_int_opt(node)
                .ok_or_else(|| anyhow!("`mouse-down` needs a button number — try `mouse-down 1`"))?
                as u8;
            Action::WdoMouseDown { button }
        }
        "mouse-up" => {
            let button = first_int_opt(node)
                .ok_or_else(|| anyhow!("`mouse-up` needs a button number — try `mouse-up 1`"))?
                as u8;
            Action::WdoMouseUp { button }
        }
        "move" => {
            // move 640 480 [relative=#true]  |  move x=640 y=480 [relative=#true]
            let ints = positional_ints(node);
            let xp = prop_integer(node, "x");
            let yp = prop_integer(node, "y");
            let (x, y) = match (ints.as_slice(), xp, yp) {
                (&[x, y], None, None) => (x as i32, y as i32),
                (&[_, _], Some(_), _) | (&[_, _], _, Some(_)) => bail!(
                    "`move`: specify coordinates as `move 640 480` OR `move x=640 y=480`, not both"
                ),
                ([], Some(x), Some(y)) => (x as i32, y as i32),
                _ => bail!(
                    "`move` needs two integer coordinates — try `move 640 480` or `move x=640 y=480`"
                ),
            };
            let relative = prop_bool_or(node, "relative", false);
            Action::WdoMouseMove { x, y, relative }
        }
        "scroll" => {
            // scroll 0 3  |  scroll dx=0 dy=3
            let ints = positional_ints(node);
            let dxp = prop_integer(node, "dx");
            let dyp = prop_integer(node, "dy");
            let (dx, dy) = match (ints.as_slice(), dxp, dyp) {
                (&[dx, dy], None, None) => (dx as i32, dy as i32),
                (&[_, _], Some(_), _) | (&[_, _], _, Some(_)) => bail!(
                    "`scroll`: specify as `scroll 0 3` OR `scroll dx=0 dy=3`, not both"
                ),
                ([], Some(dx), Some(dy)) => (dx as i32, dy as i32),
                _ => bail!(
                    "`scroll` needs two integer deltas — try `scroll 0 3` or `scroll dx=0 dy=3`"
                ),
            };
            Action::WdoScroll { dx, dy }
        }
        "focus" => {
            // focus "Firefox"  |  focus window="Firefox"
            let positional = first_string_opt(node);
            let prop = prop_string(node, "window");
            let name = match (positional, prop) {
                (Some(_), Some(_)) => bail!(
                    "`focus`: specify the window as `focus \"Firefox\"` or `focus window=\"Firefox\"`, not both"
                ),
                (Some(s), None) | (None, Some(s)) if !s.is_empty() => s,
                _ => bail!(
                    "`focus` needs a window name — try `focus \"Firefox\"`"
                ),
            };
            Action::WdoActivateWindow { name }
        }
        "wait-window" => {
            let name = first_string(node)?;
            let tms = prop_integer(node, "timeout-ms");
            let ts = prop_string(node, "timeout");
            let timeout_ms = match (tms, ts) {
                (Some(_), Some(_)) => bail!(
                    "`await-window`: specify the timeout once, as either \
                     `timeout-ms=5000` or `timeout=\"5s\"` — not both"
                ),
                (Some(v), None) => v as u64,
                (None, Some(s)) => parse_duration_ms(&s)?,
                (None, None) => 5_000,
            };
            Action::WdoAwaitWindow { name, timeout_ms }
        }
        "wait" => {
            // Accept:
            //   wait 500               (bare int, milliseconds)
            //   wait ms=500
            //   wait "1.5s" / "250ms" / "2m"
            // But only ONE of those at a time.
            let pos_int = first_int_opt(node);
            let pos_str = first_string_opt(node);
            let ms_prop = prop_integer(node, "ms");
            let present = [pos_int.is_some(), pos_str.is_some(), ms_prop.is_some()]
                .iter()
                .filter(|b| **b)
                .count();
            if present > 1 {
                bail!(
                    "`wait`: specify the duration once — `wait 500`, `wait \"1.5s\"`, \
                     or `wait ms=500`"
                );
            }
            let ms = match (pos_int, pos_str, ms_prop) {
                (Some(v), _, _) => v as u64,
                (_, Some(s), _) => parse_duration_ms(&s)?,
                (_, _, Some(v)) => v as u64,
                _ => bail!("`wait` needs a duration — try `wait 500` or `wait \"1.5s\"`"),
            };
            Action::Delay { ms }
        }
        "shell" => {
            let command = first_string(node)?;
            // Accept both `with="..."` (preferred) and `shell="..."`
            // (original, retained so pre-rename files still decode).
            // Both at once is a user mistake.
            let new_name = prop_string(node, "with");
            let old_name = prop_string(node, "shell");
            let shell = match (new_name, old_name) {
                (Some(_), Some(_)) => bail!(
                    "`shell`: set the interpreter with `with=\"/bin/bash\"` — \
                     drop the older `shell=` alias"
                ),
                (Some(s), None) | (None, Some(s)) => Some(s),
                (None, None) => None,
            };
            let capture_as = prop_string(node, "as").filter(|s| !s.is_empty());
            // Accept both `timeout-ms=30000` and `timeout="30s"`; both at
            // once is a user mistake (same shape as wait-window).
            let tms = prop_integer(node, "timeout-ms");
            let ts = prop_string(node, "timeout");
            let timeout_ms = match (tms, ts) {
                (Some(_), Some(_)) => bail!(
                    "`shell`: specify the timeout once, as either \
                     `timeout-ms=30000` or `timeout=\"30s\"` — not both"
                ),
                (Some(v), None) => Some(v as u64),
                (None, Some(s)) => Some(parse_duration_ms(&s)?),
                (None, None) => None,
            };
            let retries = prop_integer(node, "retries").unwrap_or(0);
            if retries < 0 {
                bail!("`shell`: `retries` must be >= 0, got {retries}");
            }
            let retries = retries as u32;
            // Same bi-form treatment for backoff.
            let bms = prop_integer(node, "backoff-ms");
            let bs = prop_string(node, "backoff");
            let backoff_ms = match (bms, bs) {
                (Some(_), Some(_)) => bail!(
                    "`shell`: specify the backoff once, as either \
                     `backoff-ms=500` or `backoff=\"500ms\"` — not both"
                ),
                (Some(v), None) => Some(v as u64),
                (None, Some(s)) => Some(parse_duration_ms(&s)?),
                (None, None) => None,
            };
            Action::Shell {
                command,
                shell,
                capture_as,
                timeout_ms,
                retries,
                backoff_ms,
            }
        }
        "notify" => {
            let title = first_string(node)?;
            let body = prop_string(node, "body");
            Action::Notify { title, body }
        }
        "clipboard" => {
            let text = first_string(node)?;
            Action::Clipboard { text }
        }
        "repeat" => {
            let count = first_int_opt(node)
                .ok_or_else(|| anyhow!("`repeat` needs a positive integer count — try `repeat 3 {{ ... }}`"))?;
            if count < 0 {
                bail!("`repeat` count must be >= 0, got {count}");
            }
            let children = node.children().ok_or_else(|| {
                anyhow!("`repeat {count}` must have a block `{{ ... }}` of steps")
            })?;
            let mut steps = Vec::new();
            for step_node in children.nodes() {
                steps.push(decode_step(step_node)?);
            }
            Action::Repeat {
                count: count as u32,
                steps,
            }
        }
        "use" => {
            // Unquoted bareword, `use dev-setup`, parses as a single
            // string arg in KDL v2 — same path as quoted form.
            let name = first_string(node).with_context(|| {
                "`use` needs an import name — try `use dev-setup` after declaring \
                 it in the top-level `imports { ... }` block"
            })?;
            Action::Use { name }
        }
        "when" | "unless" => {
            let verb = name; // already canonical (no alias today)
            let cond = decode_condition(node, verb)?;
            let children = node.children().ok_or_else(|| {
                anyhow!("`{verb}` must have a block `{{ ... }}` of steps")
            })?;
            let mut steps = Vec::new();
            for step_node in children.nodes() {
                steps.push(decode_step(step_node)?);
            }
            Action::Conditional {
                cond,
                negate: verb == "unless",
                steps,
            }
        }
        "note" => {
            let text = first_string(node)?;
            Action::Note { text }
        }
        other => bail!("unknown step kind `{other}`"),
    };

    let mut step = Step::new(action);
    step.enabled = !disabled;
    step.note = comment;
    step.on_error = on_error;
    // Honor a stable id if one was emitted on encode. Otherwise
    // keep the fresh UUID Step::new just generated — that's the
    // first-time-decode path (legacy files / hand-authored .kdl
    // without an _id property).
    if let Some(saved_id) = prop_string(node, "_id") {
        if !saved_id.is_empty() {
            step.id = saved_id;
        }
    }
    Ok(step)
}

fn decode_condition(node: &KdlNode, verb: &str) -> Result<Condition> {
    // Exactly one of window / file / env is required. `equals` only
    // makes sense with `env`.
    let window = prop_string(node, "window");
    let file = prop_string(node, "file");
    let env = prop_string(node, "env");
    let equals = prop_string(node, "equals");

    let present = [window.is_some(), file.is_some(), env.is_some()]
        .iter()
        .filter(|b| **b)
        .count();
    if present == 0 {
        bail!(
            "`{verb}` needs exactly one condition — try `{verb} window=\"Firefox\" {{ ... }}`, \
             `{verb} file=\"/tmp/marker\" {{ ... }}`, or `{verb} env=\"DEBUG\" {{ ... }}`"
        );
    }
    if present > 1 {
        bail!(
            "`{verb}` takes exactly one of `window=` / `file=` / `env=`, not two"
        );
    }

    if let Some(name) = window {
        if equals.is_some() {
            bail!("`{verb} window=...` doesn't take `equals=`");
        }
        return Ok(Condition::Window { name });
    }
    if let Some(path) = file {
        if equals.is_some() {
            bail!("`{verb} file=...` doesn't take `equals=`");
        }
        return Ok(Condition::File { path });
    }
    if let Some(name) = env {
        return Ok(Condition::Env { name, equals });
    }
    unreachable!()
}

/// Decode a `trigger { ... }` child of a workflow. v0.4 ships
/// `chord "..."` only; `hotstring "..."` and `when window-class=`
/// / `when window-title=` are forward-compatible KDL keys we parse
/// today so workflows authored against a future build round-trip
/// through an older one without losing data.
fn decode_trigger(node: &KdlNode) -> Result<crate::actions::Trigger> {
    use crate::actions::{Trigger, TriggerCondition, TriggerKind};
    validate_props(node, "trigger", &[])?;
    let inner = node
        .children()
        .ok_or_else(|| anyhow!("`trigger` must have a {{ ... }} body"))?;

    let mut kind: Option<TriggerKind> = None;
    let mut when: Option<TriggerCondition> = None;

    for child in inner.nodes() {
        match child.name().value() {
            "chord" => {
                if kind.is_some() {
                    bail!("`trigger` can only declare one of `chord` / `hotstring`");
                }
                let chord = first_string(child)
                    .with_context(|| "`chord` needs a string value, e.g. `chord \"ctrl+alt+d\"`")?;
                kind = Some(TriggerKind::Chord { chord });
            }
            "hotstring" => {
                if kind.is_some() {
                    bail!("`trigger` can only declare one of `chord` / `hotstring`");
                }
                let text = first_string(child)
                    .with_context(|| "`hotstring` needs a string value, e.g. `hotstring \"btw\"`")?;
                kind = Some(TriggerKind::Hotstring { text });
            }
            "when" => {
                if when.is_some() {
                    bail!("`trigger` can only have one `when` condition");
                }
                let class = prop_string(child, "window-class");
                let title = prop_string(child, "window-title");
                match (class, title) {
                    (Some(c), None) => when = Some(TriggerCondition::WindowClass { class: c }),
                    (None, Some(t)) => when = Some(TriggerCondition::WindowTitle { title: t }),
                    (None, None) => bail!(
                        "`when` needs `window-class=\"firefox\"` or `window-title=\"...\"`"
                    ),
                    (Some(_), Some(_)) => bail!(
                        "`when` takes one of `window-class=` or `window-title=`, not both"
                    ),
                }
            }
            other => bail!(
                "unknown `trigger` child `{other}` — expected `chord`, `hotstring`, or `when`"
            ),
        }
    }

    let kind = kind.ok_or_else(|| {
        anyhow!("`trigger` needs at least a `chord \"...\"` or `hotstring \"...\"`")
    })?;

    Ok(Trigger { kind, when })
}

// ---------------------------------------------------------- Helpers ---------

fn first_string(node: &KdlNode) -> Result<String> {
    for e in node.entries() {
        if e.name().is_none() {
            if let KdlValue::String(s) = e.value() {
                return Ok(s.clone());
            }
        }
    }
    Err(anyhow!(
        "`{}` needs a string argument",
        node.name().value()
    ))
}

fn first_int_opt(node: &KdlNode) -> Option<i128> {
    for e in node.entries() {
        if e.name().is_none() {
            if let KdlValue::Integer(i) = e.value() {
                return Some(*i);
            }
        }
    }
    None
}

/// All unnamed integer entries on a node, in source order. Used by
/// `move` / `scroll` which take two positional ints.
fn positional_ints(node: &KdlNode) -> Vec<i128> {
    node.entries()
        .iter()
        .filter(|e| e.name().is_none())
        .filter_map(|e| match e.value() {
            KdlValue::Integer(i) => Some(*i),
            _ => None,
        })
        .collect()
}

fn first_string_opt(node: &KdlNode) -> Option<String> {
    for e in node.entries() {
        if e.name().is_none() {
            if let KdlValue::String(s) = e.value() {
                return Some(s.clone());
            }
        }
    }
    None
}

/// Canonicalize a verb to its one-true-name. Accepts old / alias
/// forms for backwards compatibility (files written by prior releases,
/// or workflows shared by other users). The encoder only emits the
/// canonical form; the decoder accepts both.
fn canonical_verb(raw: &str) -> &str {
    match raw {
        "clip" => "clipboard",
        "await-window" => "wait-window",
        other => other,
    }
}

/// Per-action list of property names the decoder will accept, keyed by
/// the *canonical* verb name. Every action additionally accepts the
/// common step properties (see `COMMON_PROPS`). Keep in lockstep with
/// the match arms in `decode_step` — this is the single source of
/// truth for "is `shell retries=3` valid?".
///
/// `shell` accepts both `shell=` (the original, now-deprecated prop
/// name) and `with=` (the new name; `shell "cmd" shell="..."` was
/// confusing).
fn action_props(kind: &str) -> &'static [&'static str] {
    match kind {
        "type" => &["delay-ms"],
        "key" => &["clear-modifiers"],
        "key-down" => &[],
        "key-up" => &[],
        "click" => &["button"],
        "mouse-down" => &[],
        "mouse-up" => &[],
        "move" => &["x", "y", "relative"],
        "scroll" => &["dx", "dy"],
        "focus" => &["window"],
        "wait-window" => &["timeout-ms", "timeout"],
        "wait" => &["ms"],
        "shell" => &[
            "shell", "with", "as",
            "timeout", "timeout-ms",
            "retries", "backoff", "backoff-ms",
        ],
        "notify" => &["body"],
        "clipboard" => &[],
        "note" => &[],
        "repeat" => &[],
        // Conditional props: exactly one of window / file / env is
        // required. `env` may pair with `equals`.
        "when" => &["window", "file", "env", "equals"],
        "unless" => &["window", "file", "env", "equals"],
        "use" => &[],
        _ => &[],
    }
}

const COMMON_PROPS: &[&str] = &["disabled", "comment", "on-error", "_id"];

/// Walk every named entry on a step node and fail if any name isn't in
/// the action's allowlist or the common list. Unnamed (positional)
/// entries are left alone — their handling belongs to the action decoder.
fn validate_props(node: &KdlNode, kind: &str, allowed: &[&str]) -> Result<()> {
    for entry in node.entries() {
        let Some(name) = entry.name().map(|n| n.value()) else {
            continue;
        };
        if allowed.contains(&name) || COMMON_PROPS.contains(&name) {
            continue;
        }
        let valid: Vec<&str> = allowed.iter().copied().chain(COMMON_PROPS.iter().copied()).collect();
        let hint = suggest(name, &valid);
        let valid_list = if valid.is_empty() {
            String::from("(none — this action takes no properties)")
        } else {
            valid.join(", ")
        };
        bail!(
            "unknown property `{name}` on `{kind}`. valid: {valid_list}{}",
            hint.map(|s| format!(". did you mean `{s}`?")).unwrap_or_default()
        );
    }
    Ok(())
}

/// Cheap "did you mean?" — returns the closest allowlisted name if the
/// Levenshtein distance is <= 2 and strictly smaller than the candidate
/// length (so `x` doesn't suggest `y`).
fn suggest<'a>(got: &str, valid: &[&'a str]) -> Option<&'a str> {
    let mut best: Option<(&str, usize)> = None;
    for &v in valid {
        let d = levenshtein(got, v);
        if d >= got.len().max(v.len()) {
            continue;
        }
        if d > 2 {
            continue;
        }
        if best.map(|(_, bd)| d < bd).unwrap_or(true) {
            best = Some((v, d));
        }
    }
    best.map(|(s, _)| s)
}

fn levenshtein(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    if a.is_empty() {
        return b.len();
    }
    if b.is_empty() {
        return a.len();
    }
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut curr = vec![0usize; b.len() + 1];
    for (i, ca) in a.iter().enumerate() {
        curr[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let cost = if ca == cb { 0 } else { 1 };
            curr[j + 1] = (prev[j + 1] + 1).min(curr[j] + 1).min(prev[j] + cost);
        }
        std::mem::swap(&mut prev, &mut curr);
    }
    prev[b.len()]
}

/// Parse a short human duration like "250ms", "1.5s", "2m", or "1h".
/// No unit suffix defaults to milliseconds so bare numbers still work.
pub fn parse_duration_ms(s: &str) -> Result<u64> {
    let t = s.trim();
    if t.is_empty() {
        bail!("empty duration");
    }
    // Split the trailing unit letters off the numeric part.
    let (num, unit): (&str, &str) = {
        let split = t
            .char_indices()
            .find(|(_, c)| c.is_ascii_alphabetic())
            .map(|(i, _)| i)
            .unwrap_or(t.len());
        (t[..split].trim(), t[split..].trim())
    };

    let value: f64 = num
        .parse()
        .with_context(|| format!("can't parse `{num}` as a number in duration `{s}`"))?;

    let mult_ms: f64 = match unit.to_ascii_lowercase().as_str() {
        "" | "ms" => 1.0,
        "s" | "sec" | "secs" => 1_000.0,
        "m" | "min" | "mins" => 60_000.0,
        "h" | "hr" | "hrs" => 3_600_000.0,
        other => bail!("unknown duration unit `{other}` in `{s}` (use ms, s, m, or h)"),
    };

    if !value.is_finite() || value < 0.0 {
        bail!("duration must be a non-negative number: `{s}`");
    }
    Ok((value * mult_ms).round() as u64)
}

fn prop_string(node: &KdlNode, key: &str) -> Option<String> {
    for e in node.entries() {
        if e.name().map(|n| n.value()) == Some(key) {
            if let KdlValue::String(s) = e.value() {
                return Some(s.clone());
            }
        }
    }
    None
}

fn prop_integer(node: &KdlNode, key: &str) -> Option<i128> {
    for e in node.entries() {
        if e.name().map(|n| n.value()) == Some(key) {
            if let KdlValue::Integer(i) = e.value() {
                return Some(*i);
            }
        }
    }
    None
}

fn prop_bool_or(node: &KdlNode, key: &str, fallback: bool) -> bool {
    for e in node.entries() {
        if e.name().map(|n| n.value()) == Some(key) {
            if let KdlValue::Bool(b) = e.value() {
                return *b;
            }
        }
    }
    fallback
}

fn parse_ts_opt(s: &str) -> Option<chrono::DateTime<chrono::Utc>> {
    chrono::DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.with_timezone(&chrono::Utc))
}

// ---------------------------------------------------------- Tests -----------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::actions::{Action, Step};

    fn wrap(step: &str) -> String {
        format!("schema 1\nid \"t\"\ntitle \"t\"\nrecipe {{\n{step}\n}}\n")
    }

    #[test]
    fn trigger_block_round_trips() {
        use crate::actions::{Trigger, TriggerCondition, TriggerKind};
        let src = "workflow \"t\" {\n    \
            trigger {\n        chord \"super+alt+d\"\n    }\n    \
            trigger {\n        hotstring \"btw\"\n    }\n    \
            trigger {\n        chord \"ctrl+l\"\n        when window-class=\"firefox\"\n    }\n    \
            shell \"kitty\"\n}\n";
        let wf = decode(src).unwrap();
        assert_eq!(wf.triggers.len(), 3);
        assert!(matches!(
            &wf.triggers[0].kind,
            TriggerKind::Chord { chord } if chord == "super+alt+d"
        ));
        assert!(matches!(
            &wf.triggers[1].kind,
            TriggerKind::Hotstring { text } if text == "btw"
        ));
        assert!(matches!(
            &wf.triggers[2].kind,
            TriggerKind::Chord { chord } if chord == "ctrl+l"
        ));
        assert!(matches!(
            &wf.triggers[2].when,
            Some(TriggerCondition::WindowClass { class }) if class == "firefox"
        ));

        // Re-encode and parse again; trigger count + content stable.
        let again = decode(&encode(&wf)).unwrap();
        assert_eq!(again.triggers.len(), 3);
    }

    #[test]
    fn trigger_rejects_two_kinds() {
        let src = "workflow \"t\" {\n    \
            trigger {\n        chord \"ctrl+l\"\n        hotstring \"btw\"\n    }\n}\n";
        let err = decode(src).unwrap_err().to_string();
        assert!(
            err.contains("only declare one of"),
            "expected one-kind error, got: {err}"
        );
    }

    #[test]
    fn trigger_rejects_empty_block() {
        let src = "workflow \"t\" {\n    trigger { }\n}\n";
        let err = decode(src).unwrap_err().to_string();
        assert!(
            err.contains("at least") || err.contains("chord") || err.contains("hotstring"),
            "expected missing-kind error, got: {err}"
        );
    }

    #[test]
    fn key_names_are_normalized_at_decode() {
        // Hand-authored aliases get canonicalized so `show` and the
        // round-trip reflect what wdotool will actually execute.
        let src = wrap(
            "key \"Enter\"\n\
             key \"Esc\"\n\
             key \"Cmd+Shift+T\"\n\
             key-down \"Option\"\n\
             key-up \"PageDown\"",
        );
        let wf = decode(&src).unwrap();
        let chords: Vec<String> = wf
            .steps
            .iter()
            .map(|s| match &s.action {
                Action::WdoKey { chord, .. } => chord.clone(),
                Action::WdoKeyDown { chord } => chord.clone(),
                Action::WdoKeyUp { chord } => chord.clone(),
                _ => unreachable!(),
            })
            .collect();
        assert_eq!(
            chords,
            vec!["Return", "Escape", "super+shift+T", "alt", "Page_Down"]
        );
    }

    #[test]
    fn imports_and_use_splice_fragments() {
        let dir = tempfile::tempdir().unwrap();
        let dev = dir.path().join("dev.kdl");
        std::fs::write(&dev, "shell \"dev-step\"\nkey \"ctrl+l\"").unwrap();
        let standup = dir.path().join("standup.kdl");
        std::fs::write(&standup, "shell \"standup-step\"").unwrap();

        let main = dir.path().join("main.kdl");
        // Note: unquoted form `use dev-setup` — verifies bare-ident
        // parsing, mirrors the syntax users will write.
        std::fs::write(
            &main,
            r#"schema 1
id "m"
title "M"

imports {
    dev-setup "dev.kdl"
    standup   "standup.kdl"
}

recipe {
    use dev-setup
    shell "mid"
    use dev-setup
    use standup
}"#,
        )
        .unwrap();

        let wf = decode_from_file(&main).unwrap();
        // dev.kdl (2) + mid (1) + dev.kdl (2) + standup.kdl (1) = 6
        assert_eq!(wf.steps.len(), 6);
        assert!(wf.imports.is_empty(), "imports should be cleared after expand");

        // Unknown import → helpful error with a did-you-mean hint.
        let bad = dir.path().join("bad.kdl");
        std::fs::write(
            &bad,
            r#"schema 1
id "b"
title "B"
imports { dev-setup "dev.kdl" }
recipe { use dev-setpu }"#,
        )
        .unwrap();
        let err = decode_from_file(&bad).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("unknown import `dev-setpu`"), "got: {msg}");
        assert!(msg.contains("did you mean `dev-setup`"), "got: {msg}");

        // No imports at all but `use X` → helpful error.
        let empty = dir.path().join("empty.kdl");
        std::fs::write(
            &empty,
            "schema 1\nid \"e\"\ntitle \"E\"\nrecipe { use something }\n",
        )
        .unwrap();
        let err = decode_from_file(&empty).unwrap_err();
        let msg = format!("{err:#}");
        assert!(
            msg.contains("no imports declared"),
            "got: {msg}"
        );

        // Duplicate import name → error.
        let dup = dir.path().join("dup.kdl");
        std::fs::write(
            &dup,
            r#"schema 1
id "d"
title "D"
imports {
    dev-setup "dev.kdl"
    dev-setup "standup.kdl"
}
recipe { }"#,
        )
        .unwrap();
        let err = decode_from_file(&dup).unwrap_err();
        assert!(format!("{err:#}").contains("duplicate import"));
    }

    #[test]
    fn use_expands_inside_repeat_and_when() {
        let dir = tempfile::tempdir().unwrap();
        let frag = dir.path().join("frag.kdl");
        std::fs::write(&frag, r#"key "inner""#).unwrap();
        let main = dir.path().join("main.kdl");
        std::fs::write(
            &main,
            r#"schema 1
id "m"
title "M"
imports { frag "frag.kdl" }
recipe {
    repeat 2 {
        use frag
    }
    when env="HOME" {
        use frag
    }
}"#,
        )
        .unwrap();
        let wf = decode_from_file(&main).unwrap();
        match &wf.steps[0].action {
            Action::Repeat { steps, .. } => assert_eq!(steps.len(), 1),
            _ => panic!("expected repeat"),
        }
        match &wf.steps[1].action {
            Action::Conditional { steps, .. } => assert_eq!(steps.len(), 1),
            _ => panic!("expected when"),
        }
    }

    #[test]
    fn use_cycle_is_detected() {
        // A fragment that `use`s a name resolving back to itself (the
        // parent's imports map is inherited into nested splices) should
        // produce a cycle error instead of recursing forever.
        let dir = tempfile::tempdir().unwrap();
        let frag = dir.path().join("frag.kdl");
        std::fs::write(&frag, "use frag").unwrap();
        let main = dir.path().join("main.kdl");
        std::fs::write(
            &main,
            r#"schema 1
id "m"
title "M"
imports { frag "frag.kdl" }
recipe { use frag }"#,
        )
        .unwrap();
        let err = decode_from_file(&main).unwrap_err();
        assert!(
            format!("{err:#}").contains("cycle"),
            "expected cycle error, got: {err:#}"
        );
    }

    #[test]
    fn same_import_in_sibling_branches_is_fine() {
        // Visited is reset per sibling branch, so the same fragment used
        // twice at the top level is not a cycle.
        let dir = tempfile::tempdir().unwrap();
        let frag = dir.path().join("frag.kdl");
        std::fs::write(&frag, r#"key "f""#).unwrap();
        let main = dir.path().join("main.kdl");
        std::fs::write(
            &main,
            r#"schema 1
id "m"
title "M"
imports { frag "frag.kdl" }
recipe {
    use frag
    use frag
}"#,
        )
        .unwrap();
        let wf = decode_from_file(&main).unwrap();
        assert_eq!(wf.steps.len(), 2);
    }

    #[test]
    fn when_unless_round_trip() {
        let src = wrap(
            "when window=\"Firefox\" {\n\
             \t\tkey \"ctrl+l\"\n\
             \t}\n\
             \tunless file=\"/tmp/marker\" {\n\
             \t\tshell \"echo gate\"\n\
             \t}\n\
             \twhen env=\"DEBUG\" equals=\"1\" {\n\
             \t\tnote \"debug on\"\n\
             \t}",
        );
        let wf = decode(&src).unwrap();
        assert_eq!(wf.steps.len(), 3);

        match &wf.steps[0].action {
            Action::Conditional { cond: Condition::Window { name }, negate: false, steps } => {
                assert_eq!(name, "Firefox");
                assert_eq!(steps.len(), 1);
            }
            _ => panic!("expected when window=..."),
        }
        match &wf.steps[1].action {
            Action::Conditional { cond: Condition::File { path }, negate: true, .. } => {
                assert_eq!(path, "/tmp/marker");
            }
            _ => panic!("expected unless file=..."),
        }
        match &wf.steps[2].action {
            Action::Conditional { cond: Condition::Env { name, equals }, negate: false, .. } => {
                assert_eq!(name, "DEBUG");
                assert_eq!(equals.as_deref(), Some("1"));
            }
            _ => panic!("expected when env=..."),
        }

        // Round-trip preserves verb and condition shape.
        let text = encode(&wf);
        assert!(text.contains("when "), "got:\n{text}");
        assert!(text.contains("unless "), "got:\n{text}");
        let back = decode(&text).unwrap();
        assert_eq!(back.steps.len(), 3);
    }

    #[test]
    fn when_requires_exactly_one_condition() {
        let err = format!("{:#}", decode(&wrap("when { }")).unwrap_err());
        assert!(err.contains("exactly one condition"), "got: {err}");

        let err = format!("{:#}", decode(&wrap("when window=\"X\" file=\"/p\" { }")).unwrap_err());
        assert!(err.contains("exactly one"), "got: {err}");

        // equals only makes sense with env
        let err = format!(
            "{:#}",
            decode(&wrap("when window=\"X\" equals=\"v\" { }")).unwrap_err()
        );
        assert!(err.contains("doesn't take `equals="), "got: {err}");
    }

    #[test]
    fn repeat_block_round_trips() {
        let src = wrap(
            "repeat 3 {\n\
             \t\tkey \"Tab\"\n\
             \t\twait 50\n\
             \t}",
        );
        let wf = decode(&src).unwrap();
        assert_eq!(wf.steps.len(), 1);
        match &wf.steps[0].action {
            Action::Repeat { count, steps } => {
                assert_eq!(*count, 3);
                assert_eq!(steps.len(), 2);
                assert!(matches!(steps[0].action, Action::WdoKey { .. }));
                assert!(matches!(steps[1].action, Action::Delay { ms: 50 }));
            }
            _ => panic!("expected Repeat"),
        }
        let text = encode(&wf);
        assert!(text.contains("repeat 3"), "got:\n{text}");
        let again = decode(&text).unwrap();
        match &again.steps[0].action {
            Action::Repeat { count, steps } => {
                assert_eq!(*count, 3);
                assert_eq!(steps.len(), 2);
            }
            _ => panic!("expected Repeat"),
        }
    }

    #[test]
    fn repeat_requires_a_block_and_nonnegative_count() {
        let err = format!("{:#}", decode(&wrap("repeat")).unwrap_err());
        assert!(err.contains("needs a positive integer count"), "got: {err}");
        let err = format!("{:#}", decode(&wrap("repeat -3 { }")).unwrap_err());
        assert!(err.contains("count must be >= 0"), "got: {err}");
        let err = format!("{:#}", decode(&wrap("repeat 5")).unwrap_err());
        assert!(err.contains("must have a block"), "got: {err}");
    }

    #[test]
    fn repeat_nested_round_trips() {
        let src = wrap(
            "repeat 2 {\n\
             \t\trepeat 3 {\n\
             \t\t\tkey \"Tab\"\n\
             \t\t}\n\
             \t}",
        );
        let wf = decode(&src).unwrap();
        match &wf.steps[0].action {
            Action::Repeat { count: 2, steps: outer } => match &outer[0].action {
                Action::Repeat { count: 3, steps: inner } => {
                    assert_eq!(inner.len(), 1);
                }
                _ => panic!("expected inner Repeat"),
            },
            _ => panic!("expected outer Repeat"),
        }
    }

    #[test]
    fn shell_retries_round_trip() {
        let src = wrap(
            "shell \"flaky\" retries=3 backoff=\"250ms\"\n\
             shell \"once\"",
        );
        let wf = decode(&src).unwrap();
        match &wf.steps[0].action {
            Action::Shell { retries, backoff_ms, .. } => {
                assert_eq!(*retries, 3);
                assert_eq!(*backoff_ms, Some(250));
            }
            _ => panic!("expected shell"),
        }
        match &wf.steps[1].action {
            Action::Shell { retries, backoff_ms, .. } => {
                assert_eq!(*retries, 0);
                assert_eq!(*backoff_ms, None);
            }
            _ => panic!("expected shell"),
        }

        // Encode + re-decode.
        let text = encode(&wf);
        assert!(text.contains("retries=3"), "got:\n{text}");
        let back = decode(&text).unwrap();
        match &back.steps[0].action {
            Action::Shell { retries, backoff_ms, .. } => {
                assert_eq!(*retries, 3);
                assert_eq!(*backoff_ms, Some(250));
            }
            _ => panic!(),
        }

        // Both backoff forms at once → error
        let err = decode(&wrap(
            r#"shell "x" retries=1 backoff-ms=500 backoff="500ms""#,
        ))
        .unwrap_err();
        assert!(format!("{err:#}").contains("not both"), "got: {err:#}");

        // Negative retries → error
        let err = decode(&wrap(r#"shell "x" retries=-1"#)).unwrap_err();
        assert!(format!("{err:#}").contains("must be >= 0"), "got: {err:#}");
    }

    #[test]
    fn shell_timeout_accepts_both_forms() {
        // Bare-int ms, string form, and no-timeout all decode.
        let src = wrap(
            "shell \"a\" timeout-ms=5000\n\
             shell \"b\" timeout=\"10s\"\n\
             shell \"c\"",
        );
        let wf = decode(&src).unwrap();
        let timeouts: Vec<Option<u64>> = wf
            .steps
            .iter()
            .map(|s| match &s.action {
                Action::Shell { timeout_ms, .. } => *timeout_ms,
                _ => None,
            })
            .collect();
        assert_eq!(timeouts, vec![Some(5_000), Some(10_000), None]);

        // Both forms at once is a user mistake.
        let err = decode(&wrap(
            r#"shell "x" timeout-ms=5000 timeout="10s""#,
        ))
        .unwrap_err();
        assert!(format!("{err:#}").contains("not both"), "got: {err:#}");
    }

    #[test]
    fn on_error_round_trips_and_defaults_stop() {
        // Default = stop → not serialized.
        let mut wf = Workflow::new("t");
        wf.steps.push(Step::new(Action::Note { text: "a".into() }));
        wf.steps.push({
            let mut s = Step::new(Action::Shell {
                command: "false".into(),
                shell: None,
                capture_as: None,
                timeout_ms: None,
                retries: 0,
                backoff_ms: None,
            });
            s.on_error = OnError::Continue;
            s
        });
        let text = encode(&wf);
        // Only the Continue step should mention on-error.
        let occurrences = text.matches("on-error").count();
        assert_eq!(occurrences, 1, "got:\n{text}");
        assert!(text.contains("on-error=continue"), "got:\n{text}");

        // Round trips.
        let back = decode(&text).unwrap();
        assert_eq!(back.steps[0].on_error, OnError::Stop);
        assert_eq!(back.steps[1].on_error, OnError::Continue);
    }

    #[test]
    fn on_error_accepts_stop_and_continue_only() {
        // "stop" and "continue" both parse.
        let src = wrap(
            "shell \"false\" on-error=\"continue\"\n\
             shell \"false\" on-error=\"stop\"",
        );
        let wf = decode(&src).unwrap();
        assert_eq!(wf.steps[0].on_error, OnError::Continue);
        assert_eq!(wf.steps[1].on_error, OnError::Stop);

        // Garbage value errors.
        let err = decode(&wrap(r#"shell "false" on-error="lol""#)).unwrap_err();
        assert!(format!("{err:#}").contains("must be"), "got: {err:#}");
    }

    #[test]
    fn vars_block_round_trips() {
        let src = r#"schema 1
            id "t"
            title "t"
            vars {
                username "matt"
                project "wflow"
            }
            recipe {
                type "{{username}} / {{project}}"
            }"#;
        let wf = decode(src).unwrap();
        assert_eq!(wf.vars.get("username").map(String::as_str), Some("matt"));
        assert_eq!(wf.vars.get("project").map(String::as_str), Some("wflow"));
        let text = encode(&wf);
        assert!(text.contains("vars "), "got:\n{text}");
        let again = decode(&text).unwrap();
        assert_eq!(again.vars, wf.vars);
    }

    #[test]
    fn vars_cannot_shadow_env_namespace() {
        let src = r#"schema 1 id "t" title "t"
            vars {
                env.PATH "nope"
            }
            recipe { }"#;
        let err = decode(src).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("env.*"), "got: {msg}");
        assert!(msg.contains("reserved"), "got: {msg}");
    }

    #[test]
    fn shell_as_captures_into_var() {
        let src = wrap(r#"shell "date +%F" as="today""#);
        let wf = decode(&src).unwrap();
        match &wf.steps[0].action {
            Action::Shell { capture_as, .. } => {
                assert_eq!(capture_as.as_deref(), Some("today"));
            }
            _ => panic!("expected shell"),
        }
    }

    #[test]
    fn substitute_resolves_known_vars_and_errors_on_unknown() {
        use crate::actions::substitute;
        let mut vars = crate::actions::VarMap::new();
        vars.insert("who".into(), "matt".into());

        assert_eq!(substitute("hello {{who}}", &vars).unwrap(), "hello matt");
        assert_eq!(substitute("{{who}}+{{who}}", &vars).unwrap(), "matt+matt");
        // Backslash-escape keeps the literal.
        assert_eq!(substitute(r"literal \{{who}}", &vars).unwrap(), "literal {{who}}");
        // Unknown → error with a hint.
        let err = substitute("hi {{nope}}", &vars).unwrap_err();
        assert!(format!("{err:#}").contains("unknown variable"));
        assert!(format!("{err:#}").contains("known: who"));
        // Unclosed.
        assert!(substitute("{{who", &vars).is_err());
    }

    #[test]
    fn substitute_reads_env_prefix() {
        use crate::actions::substitute;
        std::env::set_var("WFLOW_TEST_VAR_XY", "yep");
        let vars = crate::actions::VarMap::new();
        assert_eq!(substitute("x={{env.WFLOW_TEST_VAR_XY}}", &vars).unwrap(), "x=yep");
        std::env::remove_var("WFLOW_TEST_VAR_XY");
        assert!(substitute("{{env.WFLOW_TEST_VAR_XY}}", &vars).is_err());
    }

    #[test]
    fn old_verb_names_still_decode() {
        // `clip` → `clipboard`, `await-window` → `wait-window`. Old files
        // keep working; only the encoder switches to the new names.
        let src = wrap(
            "clip \"copied\"\n\
             await-window \"Firefox\" timeout=\"5s\"",
        );
        let wf = decode(&src).unwrap();
        let actions: Vec<_> = wf.steps.iter().map(|s| s.action.category()).collect();
        assert_eq!(actions, vec!["clipboard", "wait"]);
    }

    #[test]
    fn shell_prop_accepts_old_and_new_names() {
        // `shell="..."` (old) and `with="..."` (new) both work.
        let a = decode(&wrap(r#"shell "echo hi" with="/bin/bash""#)).unwrap();
        let b = decode(&wrap(r#"shell "echo hi" shell="/bin/bash""#)).unwrap();
        let ja = serde_json::to_value(&a.steps[0].action).unwrap();
        let jb = serde_json::to_value(&b.steps[0].action).unwrap();
        assert_eq!(ja, jb);

        // Both at once is a user mistake.
        let err = decode(&wrap(r#"shell "echo hi" with="/bin/bash" shell="/bin/bash""#))
            .unwrap_err();
        assert!(format!("{err:#}").contains("drop the older `shell=` alias"));
    }

    #[test]
    fn encoder_emits_canonical_names() {
        let mut wf = Workflow::new("t");
        wf.steps.push(Step::new(Action::Clipboard { text: "copied".into() }));
        wf.steps.push(Step::new(Action::WdoAwaitWindow {
            name: "Firefox".into(),
            timeout_ms: 5_000,
        }));
        wf.steps.push(Step::new(Action::Shell {
            command: "echo hi".into(),
            shell: Some("/bin/bash".into()),
            capture_as: None,
            timeout_ms: None,
            retries: 0,
            backoff_ms: None,
        }));
        let text = encode(&wf);
        // KDL autoformat drops quotes when strings are bareword-safe, so
        // match the verb + content on a word boundary instead.
        assert!(text.contains("clipboard copied") || text.contains("clipboard \"copied\""), "got:\n{text}");
        assert!(text.contains("wait-window Firefox") || text.contains("wait-window \"Firefox\""), "got:\n{text}");
        assert!(text.contains("with=\"/bin/bash\"") || text.contains("with=/bin/bash"), "got:\n{text}");
        // No lingering old names on canonical output.
        for line in text.lines() {
            let trimmed = line.trim_start();
            assert!(
                !trimmed.starts_with("clip ") && !trimmed.starts_with("clip\""),
                "line leaks old `clip` verb: {line}"
            );
            assert!(
                !trimmed.starts_with("await-window"),
                "line leaks old `await-window` verb: {line}"
            );
        }
    }

    #[test]
    fn positional_and_prop_forms_both_decode() {
        // Both syntaxes for focus / click / move / scroll parse to the
        // same Action.
        let new_form = wrap(
            "focus \"Firefox\"\n\
             click 2\n\
             move 640 480 relative=#true\n\
             scroll 0 3",
        );
        let old_form = wrap(
            "focus window=\"Firefox\"\n\
             click button=2\n\
             move x=640 y=480 relative=#true\n\
             scroll dx=0 dy=3",
        );
        let a = decode(&new_form).unwrap().steps;
        let b = decode(&old_form).unwrap().steps;
        assert_eq!(a.len(), 4);
        for (sa, sb) in a.iter().zip(b.iter()) {
            let ja = serde_json::to_value(&sa.action).unwrap();
            let jb = serde_json::to_value(&sb.action).unwrap();
            assert_eq!(ja, jb);
        }
    }

    #[test]
    fn positional_and_prop_conflict_rejected() {
        let cases: &[(&str, &str)] = &[
            (r#"focus "X" window="Y""#, "not both"),
            (r#"click 1 button=2"#, "not both"),
            (r#"move 1 2 x=3 y=4"#, "not both"),
            (r#"scroll 0 3 dx=0 dy=3"#, "not both"),
            (r#"await-window "X" timeout-ms=5000 timeout="10s""#, "not both"),
            (r#"wait 500 ms=300"#, "specify the duration once"),
            (r#"wait "1.5s" ms=500"#, "specify the duration once"),
        ];
        for (step, expected) in cases {
            let msg = format!("{:#}", decode(&wrap(step)).unwrap_err());
            assert!(msg.contains(expected), "step `{step}`, got: {msg}");
        }
    }

    #[test]
    fn move_and_scroll_require_both_coords() {
        let msg = format!("{:#}", decode(&wrap("move x=10")).unwrap_err());
        assert!(msg.contains("`move` needs two integer coordinates"), "got: {msg}");

        let msg = format!("{:#}", decode(&wrap("scroll 0")).unwrap_err());
        assert!(msg.contains("`scroll` needs two integer deltas"), "got: {msg}");
    }

    #[test]
    fn missing_required_fields_are_rejected() {
        // Missing id
        let src = r#"schema 1
            title "t"
            recipe { }"#;
        let msg = format!("{:#}", decode(src).unwrap_err());
        assert!(msg.contains("missing required `id"), "got: {msg}");

        // Missing title
        let src = r#"schema 1
            id "t"
            recipe { }"#;
        let msg = format!("{:#}", decode(src).unwrap_err());
        assert!(msg.contains("missing required `title"), "got: {msg}");

        // Missing recipe
        let src = r#"schema 1
            id "t"
            title "t""#;
        let msg = format!("{:#}", decode(src).unwrap_err());
        assert!(msg.contains("missing required `recipe"), "got: {msg}");
    }

    #[test]
    fn unknown_schema_version_is_rejected() {
        let src = r#"schema 42
            id "t"
            title "t"
            recipe { }"#;
        let msg = format!("{:#}", decode(src).unwrap_err());
        assert!(msg.contains("schema 42 is not supported"), "got: {msg}");
    }

    #[test]
    fn unknown_top_level_node_is_rejected_with_hint() {
        let src = r#"schema 1
            id "t"
            title "t"
            recipie { }"#; // typo
        let msg = format!("{:#}", decode(src).unwrap_err());
        assert!(msg.contains("unknown top-level node `recipie`"), "got: {msg}");
        assert!(msg.contains("did you mean `recipe`"), "got: {msg}");
    }

    #[test]
    fn unknown_props_are_rejected_with_suggestion() {
        // Typo close enough to be a "did you mean" hit.
        let src = r#"
            schema 1
            id "t"
            title "t"
            recipe { click buton=1 }
        "#;
        let err = decode(src).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("unknown property `buton`"), "got: {msg}");
        assert!(msg.contains("did you mean `button`"), "got: {msg}");

        // Totally foreign prop → listed options, no hint.
        let src = r#"
            schema 1
            id "t"
            title "t"
            recipe { shell "cmd" gizmo=3 }
        "#;
        let err = decode(src).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("unknown property `gizmo`"), "got: {msg}");
        assert!(
            msg.contains("shell, with, as, timeout, timeout-ms, retries, backoff, backoff-ms, disabled, comment"),
            "got: {msg}"
        );
    }

    #[test]
    fn common_props_still_work() {
        let src = r#"
            schema 1
            id "t"
            title "t"
            recipe {
                key "Return" disabled=#true comment="temp"
            }
        "#;
        let wf = decode(src).expect("disabled + comment must remain valid");
        assert_eq!(wf.steps.len(), 1);
        assert!(!wf.steps[0].enabled);
        assert_eq!(wf.steps[0].note.as_deref(), Some("temp"));
    }

    #[test]
    fn note_rejects_foreign_prop() {
        // `note` takes no properties. A property here is clearly a mistake.
        let src = r#"
            schema 1
            id "t"
            title "t"
            recipe { note "hi" important=#true }
        "#;
        let err = decode(src).unwrap_err();
        assert!(format!("{err:#}").contains("unknown property `important`"));
    }

    #[test]
    fn duration_parser_handles_common_shapes() {
        assert_eq!(parse_duration_ms("500").unwrap(), 500);
        assert_eq!(parse_duration_ms("500ms").unwrap(), 500);
        assert_eq!(parse_duration_ms("1.5s").unwrap(), 1500);
        assert_eq!(parse_duration_ms("2s").unwrap(), 2000);
        assert_eq!(parse_duration_ms("2m").unwrap(), 120_000);
        assert_eq!(parse_duration_ms("1h").unwrap(), 3_600_000);
        assert_eq!(parse_duration_ms(" 250 ms ").unwrap(), 250);
        // Errors
        assert!(parse_duration_ms("").is_err());
        assert!(parse_duration_ms("abc").is_err());
        assert!(parse_duration_ms("-5s").is_err());
        assert!(parse_duration_ms("5y").is_err());
    }

    #[test]
    fn wait_accepts_bare_int_prop_and_string() {
        let src = r#"
            schema 1
            id "t"
            title "t"
            recipe {
                wait 500
                wait ms=250
                wait "1.5s"
                wait "2m"
            }
        "#;
        let wf = decode(src).unwrap();
        let ms: Vec<u64> = wf
            .steps
            .iter()
            .filter_map(|s| match &s.action {
                Action::Delay { ms } => Some(*ms),
                _ => None,
            })
            .collect();
        assert_eq!(ms, vec![500, 250, 1500, 120_000]);
    }

    #[test]
    fn round_trip_preserves_every_action() {
        let mut wf = Workflow::new("test");
        wf.subtitle = Some("end-to-end".into());

        let mut s1 = Step::new(Action::WdoType {
            text: "hello \"world\"".into(),
            delay_ms: Some(30),
        });
        s1.note = Some("greet first".into());

        let mut s2 = Step::new(Action::WdoKey {
            chord: "ctrl+shift+p".into(),
            clear_modifiers: true,
        });
        s2.enabled = false;

        wf.steps = vec![
            s1,
            s2,
            Step::new(Action::WdoKeyDown { chord: "shift".into() }),
            Step::new(Action::WdoKeyUp { chord: "shift".into() }),
            Step::new(Action::WdoMouseDown { button: 1 }),
            Step::new(Action::WdoMouseUp { button: 1 }),
            Step::new(Action::WdoClick { button: 1 }),
            Step::new(Action::WdoMouseMove { x: 10, y: -5, relative: true }),
            Step::new(Action::WdoScroll { dx: 0, dy: 3 }),
            Step::new(Action::WdoActivateWindow { name: "Firefox".into() }),
            Step::new(Action::WdoAwaitWindow { name: "Firefox".into(), timeout_ms: 7500 }),
            Step::new(Action::Delay { ms: 500 }),
            Step::new(Action::Shell { command: "echo hi".into(), shell: None, capture_as: None, timeout_ms: None, retries: 0, backoff_ms: None }),
            Step::new(Action::Shell { command: "date +%F".into(), shell: None, capture_as: Some("today".into()), timeout_ms: Some(30_000), retries: 3, backoff_ms: Some(250) }),
            Step::new(Action::Notify { title: "done".into(), body: Some("all good".into()) }),
            Step::new(Action::Clipboard { text: "copied".into() }),
            Step::new(Action::Note { text: "remember to disable VPN".into() }),
        ];
        wf.vars.insert("username".into(), "matt".into());
        wf.vars.insert("app".into(), "firefox".into());

        let text = encode(&wf);
        let back = decode(&text).expect("decode should succeed");

        assert_eq!(back.title, wf.title);
        assert_eq!(back.subtitle, wf.subtitle);
        assert_eq!(back.steps.len(), wf.steps.len());
        assert_eq!(back.vars, wf.vars);

        // Compare actions pairwise via serde_json (easy structural compare).
        for (a, b) in wf.steps.iter().zip(back.steps.iter()) {
            let ja = serde_json::to_value(&a.action).unwrap();
            let jb = serde_json::to_value(&b.action).unwrap();
            assert_eq!(ja, jb, "action changed through round trip");
            assert_eq!(a.enabled, b.enabled, "enabled flag changed");
            assert_eq!(a.note, b.note, "note changed");
        }
    }

    // ---------- New (v0.4) workflow-block format -------------------

    #[test]
    fn new_format_minimal_decodes() {
        let src = r#"workflow "Hello" {
            note "first step"
            shell "echo hi"
        }
        "#;
        let wf = decode(src).expect("minimal new-format file should decode");
        assert_eq!(wf.title, "Hello");
        assert_eq!(wf.id, ""); // caller fills from filename
        assert_eq!(wf.subtitle, None);
        assert_eq!(wf.steps.len(), 2);
    }

    #[test]
    fn new_format_subtitle_as_child_node() {
        let src = r#"workflow "Morning standup" {
            subtitle "open slack, paste the standard message"
            note "step a"
        }
        "#;
        let wf = decode(src).unwrap();
        assert_eq!(wf.title, "Morning standup");
        assert_eq!(
            wf.subtitle.as_deref(),
            Some("open slack, paste the standard message")
        );
        assert_eq!(wf.steps.len(), 1);
    }

    #[test]
    fn new_format_with_vars_and_imports() {
        // The `#` in `#standup` would close an r#"..."# raw string
        // early, so use r##"..."## to give the delimiter more padding.
        let src = r##"workflow "Daily standup" {
            subtitle "templated message"
            vars {
                channel "#standup"
                ticket "DUR-1"
            }
            imports {
                template "./template.kdl"
            }
            type "{{channel}}"
        }
        "##;
        let wf = decode(src).unwrap();
        assert_eq!(wf.vars.get("channel").map(String::as_str), Some("#standup"));
        assert_eq!(
            wf.imports.get("template").map(String::as_str),
            Some("./template.kdl")
        );
        assert_eq!(wf.steps.len(), 1);
    }

    #[test]
    fn new_format_rejects_legacy_id_inside_workflow() {
        let src = r#"workflow "X" {
            id "should-not-be-here"
            note "x"
        }
        "#;
        let err = decode(src).unwrap_err().to_string();
        assert!(
            err.contains("filename is the id"),
            "expected friendly id-doesn't-belong message, got: {err}"
        );
    }

    #[test]
    fn new_format_rejects_legacy_recipe_wrapper() {
        let src = r#"workflow "X" {
            recipe {
                note "x"
            }
        }
        "#;
        let err = decode(src).unwrap_err().to_string();
        assert!(
            err.contains("recipe"),
            "expected recipe-wrapper rejection, got: {err}"
        );
    }

    #[test]
    fn new_format_rejects_mixed_with_legacy_top_level() {
        let src = r#"schema 1
id "x"
workflow "X" {
    note "x"
}
"#;
        let err = decode(src).unwrap_err().to_string();
        assert!(
            err.contains("mixes the legacy top-level layout"),
            "expected mixed-format rejection, got: {err}"
        );
    }

    #[test]
    fn new_format_rejects_multiple_workflow_blocks_with_future_hint() {
        let src = r#"workflow "A" { note "a" }
workflow "B" { note "b" }
"#;
        let err = decode(src).unwrap_err().to_string();
        assert!(
            err.contains("future release"),
            "expected future-feature rejection, got: {err}"
        );
    }

    #[test]
    fn new_format_missing_title_errors_helpfully() {
        let src = r#"workflow {
            note "x"
        }
        "#;
        let err = decode(src).unwrap_err().to_string();
        assert!(
            err.contains("title"),
            "expected title-required message, got: {err}"
        );
    }

    #[test]
    fn legacy_format_still_decodes() {
        // Sanity: old files keep working alongside the new path.
        let src = r#"schema 1
id "legacy-1"
title "Legacy Workflow"
subtitle "from before v0.4"
recipe {
    note "still works"
}
"#;
        let wf = decode(src).expect("legacy file should still decode");
        assert_eq!(wf.id, "legacy-1");
        assert_eq!(wf.title, "Legacy Workflow");
        assert_eq!(wf.subtitle.as_deref(), Some("from before v0.4"));
        assert_eq!(wf.steps.len(), 1);
    }
}

#[cfg(test)]
mod fragment_roundtrip {
    use super::*;

    #[test]
    fn fragment_encode_then_decode_preserves_steps() {
        // Build a fragment-shaped step list — the "use NAME" import
        // target form: bare nodes, no workflow wrapper.
        let dir = tempfile::tempdir().unwrap();
        let frag_path = dir.path().join("frag.kdl");
        let original = r#"note "Loaded from preamble."
shell "echo hi"
key "ctrl+l"
when window="Firefox" {
    note "Inside the conditional."
}
"#;
        std::fs::write(&frag_path, original).unwrap();

        // Decode it as a fragment.
        let steps = decode_fragment_file(&frag_path).unwrap();
        assert_eq!(steps.len(), 4);

        // Re-encode and round-trip.
        let re_encoded = encode_fragment(&steps);
        let frag_path_2 = dir.path().join("frag2.kdl");
        std::fs::write(&frag_path_2, re_encoded.as_bytes()).unwrap();
        let steps2 = decode_fragment_file(&frag_path_2).unwrap();
        assert_eq!(steps2.len(), 4);

        // Spot-check: the conditional's inner step survived nesting.
        match &steps2[3].action {
            Action::Conditional { steps: inner, .. } => {
                assert_eq!(inner.len(), 1);
            }
            _ => panic!("expected Conditional at index 3"),
        }
    }

    #[test]
    fn fragment_encode_omits_workflow_wrapper() {
        // No "workflow" / "schema" / "imports" / "title" tokens in
        // the fragment output — it must be a bare list of step
        // nodes, otherwise the fragment file becomes a malformed
        // workflow file that wouldn't decode as a fragment again.
        let mut wf = Workflow::new("title-not-emitted");
        wf.steps.push(Step::new(Action::Note { text: "hi".into() }));
        let body = encode_fragment(&wf.steps);
        assert!(!body.contains("workflow"));
        assert!(!body.contains("schema"));
        assert!(!body.contains("imports"));
        assert!(!body.contains("title-not-emitted"));
        // And the step itself IS in the output.
        assert!(body.contains("note"));
        assert!(body.contains("hi"));
    }
}
