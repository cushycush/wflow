//! Decoder. KDL string → `Workflow`. Companion to `encode`.
//!
//! Accepts the v0.4+ `workflow "title" { ... }` shape and the legacy
//! pre-v0.4 `recipe { ... }` shape (lazy migration: re-encoding always
//! emits the new shape, so legacy files round-trip on the next save).

use anyhow::{anyhow, bail, Context, Result};
use kdl::{KdlDocument, KdlNode, KdlValue};

use crate::actions::{normalize_chord, Action, Condition, OnError, Step, Workflow};

use super::parse_duration_ms;

/// On-disk schema version. Bumped when the file format makes a
/// breaking change; the decoder rejects any other value with a
/// human-readable error pointing at `wflow migrate`.
const SCHEMA_VERSION: i128 = 1;

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

pub(super) fn decode_step(node: &KdlNode) -> Result<Step> {
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
            let mut else_steps: Vec<Step> = Vec::new();
            let mut saw_else = false;
            for step_node in children.nodes() {
                let child_name = step_node.name().value();
                if child_name == "else" {
                    if saw_else {
                        return Err(anyhow!(
                            "`{verb}` block can only have one `else` branch"
                        ));
                    }
                    saw_else = true;
                    let else_children = step_node.children().ok_or_else(|| {
                        anyhow!("`else` must have a block `{{ ... }}` of steps")
                    })?;
                    for inner in else_children.nodes() {
                        else_steps.push(decode_step(inner)?);
                    }
                    continue;
                }
                if saw_else {
                    return Err(anyhow!(
                        "steps after `else {{ ... }}` aren't allowed inside a `{verb}` block; \
                         move them outside or into the else branch"
                    ));
                }
                steps.push(decode_step(step_node)?);
            }
            Action::Conditional {
                cond,
                negate: verb == "unless",
                steps,
                else_steps,
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
pub(super) fn suggest<'a>(got: &str, valid: &[&'a str]) -> Option<&'a str> {
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
