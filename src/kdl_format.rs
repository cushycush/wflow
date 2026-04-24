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

use crate::actions::{Action, Step, Workflow};

pub const SCHEMA_VERSION: i128 = 1;

// ---------------------------------------------------------- Encoding --------

pub fn encode(wf: &Workflow) -> String {
    let mut doc = KdlDocument::new();

    doc.nodes_mut().push(kv_int("schema", SCHEMA_VERSION));
    doc.nodes_mut().push(kv_str("id", &wf.id));
    doc.nodes_mut().push(kv_str("title", &wf.title));
    if let Some(s) = &wf.subtitle {
        if !s.is_empty() {
            doc.nodes_mut().push(kv_str("subtitle", s));
        }
    }
    if let Some(t) = wf.created {
        doc.nodes_mut().push(kv_str("created", &t.to_rfc3339()));
    }
    if let Some(t) = wf.modified {
        doc.nodes_mut().push(kv_str("modified", &t.to_rfc3339()));
    }
    if let Some(t) = wf.last_run {
        doc.nodes_mut().push(kv_str("last-run", &t.to_rfc3339()));
    }

    // Optional variables block. Only emitted if the workflow actually
    // carries any — keeps files without vars clean.
    if !wf.vars.is_empty() {
        let mut vars_node = KdlNode::new("vars");
        let mut inner = KdlDocument::new();
        for (k, v) in &wf.vars {
            inner.nodes_mut().push(kv_str(k, v));
        }
        vars_node.set_children(inner);
        doc.nodes_mut().push(vars_node);
    }

    let mut recipe = KdlNode::new("recipe");
    let mut inner = KdlDocument::new();
    for step in &wf.steps {
        inner.nodes_mut().push(encode_step(step));
    }
    recipe.set_children(inner);
    doc.nodes_mut().push(recipe);

    doc.autoformat();
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
        Action::WdoClick { button } => {
            let mut n = KdlNode::new("click");
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
        Action::Shell { command, shell, capture_as } => {
            let mut n = KdlNode::new("shell");
            n.push(arg_str(command));
            if let Some(s) = shell {
                n.push(prop_str("with", s));
            }
            if let Some(name) = capture_as {
                n.push(prop_str("as", name));
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

pub fn decode(src: &str) -> Result<Workflow> {
    let doc: KdlDocument = src.parse().context("parsing KDL")?;

    let mut id: Option<String> = None;
    let mut title: Option<String> = None;
    let mut subtitle: Option<String> = None;
    let mut created = None;
    let mut modified = None;
    let mut last_run = None;
    let mut steps: Vec<Step> = Vec::new();
    let mut vars: std::collections::BTreeMap<String, String> = Default::default();
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
                    "modified", "last-run", "vars", "recipe",
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
        created,
        modified,
        last_run,
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

    let action: Action = match name {
        "type" => {
            let text = first_string(node)?;
            let delay_ms = prop_integer(node,"delay-ms").map(|n| n as u32);
            Action::WdoType { text, delay_ms }
        }
        "key" => {
            let chord = first_string(node)?;
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
            Action::Shell { command, shell, capture_as }
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
        "note" => {
            let text = first_string(node)?;
            Action::Note { text }
        }
        other => bail!("unknown step kind `{other}`"),
    };

    let mut step = Step::new(action);
    step.enabled = !disabled;
    step.note = comment;
    Ok(step)
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
        "click" => &["button"],
        "move" => &["x", "y", "relative"],
        "scroll" => &["dx", "dy"],
        "focus" => &["window"],
        "wait-window" => &["timeout-ms", "timeout"],
        "wait" => &["ms"],
        "shell" => &["shell", "with", "as"],
        "notify" => &["body"],
        "clipboard" => &[],
        "note" => &[],
        _ => &[],
    }
}

const COMMON_PROPS: &[&str] = &["disabled", "comment"];

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
            recipe { shell "cmd" retries=3 }
        "#;
        let err = decode(src).unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("unknown property `retries`"), "got: {msg}");
        assert!(msg.contains("shell, with, as, disabled, comment"), "got: {msg}");
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
            Step::new(Action::WdoClick { button: 1 }),
            Step::new(Action::WdoMouseMove { x: 10, y: -5, relative: true }),
            Step::new(Action::WdoScroll { dx: 0, dy: 3 }),
            Step::new(Action::WdoActivateWindow { name: "Firefox".into() }),
            Step::new(Action::WdoAwaitWindow { name: "Firefox".into(), timeout_ms: 7500 }),
            Step::new(Action::Delay { ms: 500 }),
            Step::new(Action::Shell { command: "echo hi".into(), shell: None, capture_as: None }),
            Step::new(Action::Shell { command: "date +%F".into(), shell: None, capture_as: Some("today".into()) }),
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
}
