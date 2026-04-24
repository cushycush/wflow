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
            n.push(prop_int("button", *button as i128));
            n
        }
        Action::WdoMouseMove { x, y, relative } => {
            let mut n = KdlNode::new("move");
            n.push(prop_int("x", *x as i128));
            n.push(prop_int("y", *y as i128));
            if *relative {
                n.push(prop_bool("relative", true));
            }
            n
        }
        Action::WdoScroll { dx, dy } => {
            let mut n = KdlNode::new("scroll");
            n.push(prop_int("dx", *dx as i128));
            n.push(prop_int("dy", *dy as i128));
            n
        }
        Action::WdoActivateWindow { name } => {
            let mut n = KdlNode::new("focus");
            n.push(prop_str("window", name));
            n
        }
        Action::WdoAwaitWindow { name, timeout_ms } => {
            let mut n = KdlNode::new("await-window");
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
        Action::Shell { command, shell } => {
            let mut n = KdlNode::new("shell");
            n.push(arg_str(command));
            if let Some(s) = shell {
                n.push(prop_str("shell", s));
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
            let mut n = KdlNode::new("clip");
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
                    "modified", "last-run", "recipe",
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
        created,
        modified,
        last_run,
    })
}

fn decode_step(node: &KdlNode) -> Result<Step> {
    let name = node.name().value();

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
            let button = prop_integer(node,"button").unwrap_or(1) as u8;
            Action::WdoClick { button }
        }
        "move" => {
            let x = prop_integer(node,"x").unwrap_or(0) as i32;
            let y = prop_integer(node,"y").unwrap_or(0) as i32;
            let relative = prop_bool_or(node, "relative", false);
            Action::WdoMouseMove { x, y, relative }
        }
        "scroll" => {
            let dx = prop_integer(node,"dx").unwrap_or(0) as i32;
            let dy = prop_integer(node,"dy").unwrap_or(0) as i32;
            Action::WdoScroll { dx, dy }
        }
        "focus" => {
            let name = prop_string(node, "window").unwrap_or_default();
            Action::WdoActivateWindow { name }
        }
        "await-window" => {
            let name = first_string(node)?;
            // Accept either `timeout-ms=5000` or `timeout="5s"`.
            let timeout_ms = if let Some(v) = prop_integer(node, "timeout-ms") {
                v as u64
            } else if let Some(s) = prop_string(node, "timeout") {
                parse_duration_ms(&s)?
            } else {
                5_000
            };
            Action::WdoAwaitWindow { name, timeout_ms }
        }
        "wait" => {
            // Accept:
            //   wait 500               (bare int, milliseconds)
            //   wait ms=500
            //   wait "1.5s" / "250ms" / "2m"
            let ms = if let Some(v) = first_int_opt(node) {
                v as u64
            } else if let Some(v) = prop_integer(node, "ms") {
                v as u64
            } else if let Some(s) = first_string_opt(node) {
                parse_duration_ms(&s)?
            } else {
                bail!("`wait` needs a duration — try `wait 500` or `wait \"1.5s\"`");
            };
            Action::Delay { ms }
        }
        "shell" => {
            let command = first_string(node)?;
            let shell = prop_string(node, "shell");
            Action::Shell { command, shell }
        }
        "notify" => {
            let title = first_string(node)?;
            let body = prop_string(node, "body");
            Action::Notify { title, body }
        }
        "clip" => {
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

/// Per-action list of property names the decoder will accept. Every
/// action additionally accepts the common step properties (see
/// `COMMON_PROPS`). Keep in lockstep with the match arms in
/// `decode_step` — this is the single source of truth for "is
/// `shell retries=3` valid?".
fn action_props(kind: &str) -> &'static [&'static str] {
    match kind {
        "type" => &["delay-ms"],
        "key" => &["clear-modifiers"],
        "click" => &["button"],
        "move" => &["x", "y", "relative"],
        "scroll" => &["dx", "dy"],
        "focus" => &["window"],
        "await-window" => &["timeout-ms", "timeout"],
        "wait" => &["ms"],
        "shell" => &["shell"],
        "notify" => &["body"],
        "clip" => &[],
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
        assert!(msg.contains("shell, disabled, comment"), "got: {msg}");
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
            Step::new(Action::Shell { command: "echo hi".into(), shell: None }),
            Step::new(Action::Notify { title: "done".into(), body: Some("all good".into()) }),
            Step::new(Action::Clipboard { text: "copied".into() }),
            Step::new(Action::Note { text: "remember to disable VPN".into() }),
        ];

        let text = encode(&wf);
        let back = decode(&text).expect("decode should succeed");

        assert_eq!(back.title, wf.title);
        assert_eq!(back.subtitle, wf.subtitle);
        assert_eq!(back.steps.len(), wf.steps.len());

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
