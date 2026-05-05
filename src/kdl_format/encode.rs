//! Encoder. `Workflow` → KDL string.
//!
//! Companion to `decode`. Emits the canonical v0.4+ shape:
//!   `workflow "title" { subtitle "..." vars { ... } trigger { ... } steps... }`
//! Legacy on-disk shapes parse and round-trip through the decoder
//! into this form on the next save.

use kdl::{KdlDocument, KdlEntry, KdlIdentifier, KdlNode, KdlValue};

use crate::actions::{Action, Condition, OnError, Step, Workflow};

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
        Action::Conditional { cond, negate, steps, else_steps } => {
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
            // Else branch nests inside the when/unless block as a
            // child `else { ... }` node. Keeping it nested (rather
            // than as a sibling) makes the relationship obvious in
            // the file and means the existing decoder can skip the
            // node when an older wflow build encounters it.
            if !else_steps.is_empty() {
                let mut else_node = KdlNode::new("else");
                let mut else_inner = KdlDocument::new();
                for step in else_steps {
                    else_inner.nodes_mut().push(encode_step(step));
                }
                else_node.set_children(else_inner);
                inner.nodes_mut().push(else_node);
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
