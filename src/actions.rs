//! The action model.
//!
//! A workflow is an ordered list of `Step`s. A Step wraps an `Action` with
//! per-step metadata (id, optional comment, enabled flag). An `Action` is the
//! actual operation to perform.
//!
//! Invariant: adding a new action kind requires (1) a new `Action` variant,
//! (2) a match arm in `engine::run_action`, and (3) a Svelte editor component.
//! Nothing else should branch on action kind.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

fn default_await_timeout_ms() -> u64 {
    5_000
}

// ----------------------------- Key-name normalization ---------------------

/// Map user-friendly aliases to the X11 keysyms wdotool actually
/// wants. Applied at decode time to `key`, `key-down`, `key-up` chords,
/// so the canonical on-disk form is the one wdotool will accept and
/// the source file round-trips truthfully.
///
/// Mapping philosophy: only rewrite obvious name confusion (Enter vs
/// Return) and popular shorthands (Esc, PageUp). Anything that isn't
/// in the table passes through unchanged — the user can always write
/// the wdotool name literally.
pub fn normalize_chord(raw: &str) -> String {
    raw.split('+')
        .map(str::trim)
        .map(normalize_key_segment)
        .collect::<Vec<_>>()
        .join("+")
}

fn normalize_key_segment(part: &str) -> String {
    // Case-insensitive lookup so both `Enter` and `ENTER` land on Return.
    // The canonical form preserves the user's case for anything not in
    // the table (e.g. a literal character like "a" or "A").
    let lower = part.to_ascii_lowercase();
    match lower.as_str() {
        // Modifiers — canonicalize to lower-case spelling wdotool wants.
        "ctrl" | "control" => "ctrl".into(),
        "shift" => "shift".into(),
        "alt" => "alt".into(),
        "super" => "super".into(),
        // Colloquial / cross-platform modifier aliases.
        "cmd" | "command" | "win" | "windows" | "meta" => "super".into(),
        "option" | "opt" => "alt".into(),
        // Return / Enter confusion. Always pick Return.
        "enter" | "return" => "Return".into(),
        // Escape / Esc.
        "esc" | "escape" => "Escape".into(),
        // Everyone spells this one slightly differently; canonical is
        // BackSpace in X11 keysyms.
        "backspace" | "back_space" => "BackSpace".into(),
        "delete" | "del" => "Delete".into(),
        "insert" | "ins" => "Insert".into(),
        "capslock" | "caps" | "caps_lock" => "Caps_Lock".into(),
        "numlock" | "num_lock" => "Num_Lock".into(),
        "scrolllock" | "scroll_lock" => "Scroll_Lock".into(),
        "printscreen" | "prtsc" | "print_screen" => "Print".into(),
        "pageup" | "pgup" | "page_up" => "Page_Up".into(),
        "pagedown" | "pgdn" | "page_down" => "Page_Down".into(),
        "home" => "Home".into(),
        "end" => "End".into(),
        "left" => "Left".into(),
        "right" => "Right".into(),
        "up" => "Up".into(),
        "down" => "Down".into(),
        "tab" => "Tab".into(),
        "space" | "spacebar" => "space".into(),
        _ => part.to_string(),
    }
}

#[cfg(test)]
mod normalize_tests {
    use super::*;

    #[test]
    fn plain_aliases() {
        assert_eq!(normalize_chord("Enter"), "Return");
        assert_eq!(normalize_chord("Esc"), "Escape");
        assert_eq!(normalize_chord("PgUp"), "Page_Up");
        assert_eq!(normalize_chord("Del"), "Delete");
        assert_eq!(normalize_chord("Caps"), "Caps_Lock");
    }

    #[test]
    fn modifier_aliases_in_chords() {
        assert_eq!(normalize_chord("cmd+shift+t"), "super+shift+t");
        assert_eq!(normalize_chord("win+1"), "super+1");
        assert_eq!(normalize_chord("option+f"), "alt+f");
    }

    #[test]
    fn case_insensitive_modifiers() {
        assert_eq!(normalize_chord("ENTER"), "Return");
        // All of these canonicalize to lower-case modifier names.
        assert_eq!(normalize_chord("CTRL+SHIFT+A"), "ctrl+shift+A");
        assert_eq!(normalize_chord("Ctrl+Alt+L"), "ctrl+alt+L");
        assert_eq!(normalize_chord("ctrl+shift+a"), "ctrl+shift+a");
        assert_eq!(normalize_chord("Super+Enter"), "super+Return");
    }

    #[test]
    fn unknown_keys_pass_through() {
        assert_eq!(normalize_chord("a"), "a");
        assert_eq!(normalize_chord("F11"), "F11");
        assert_eq!(normalize_chord("ctrl+l"), "ctrl+l");
    }

    #[test]
    fn composite_with_aliased_end_key() {
        assert_eq!(normalize_chord("ctrl+Enter"), "ctrl+Return");
        assert_eq!(normalize_chord("shift+PageDown"), "shift+Page_Down");
    }
}

// ----------------------------- Template substitution ----------------------

/// Map of variable name → value, threaded through a workflow run.
/// Populated at start from the workflow's `vars {}` block, then extended
/// as `shell ... as="foo"` steps capture their stdout.
pub type VarMap = std::collections::BTreeMap<String, String>;

/// Resolve `{{name}}` tokens in `s`. Names starting with `env.` read
/// from the process environment; everything else looks up `vars`. An
/// unknown name errors with a list of known ones so typos are
/// diagnosable. `\{{...}}` keeps the literal (backslash-escape).
pub fn substitute(s: &str, vars: &VarMap) -> anyhow::Result<String> {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < bytes.len() {
        // Backslash-escape: `\{{` emits `{{` and skips substitution.
        if bytes[i] == b'\\' && bytes.get(i + 1..i + 3) == Some(b"{{") {
            out.push_str("{{");
            i += 3;
            continue;
        }
        if bytes.get(i..i + 2) == Some(b"{{") {
            let start = i + 2;
            // Find the matching `}}`.
            let mut end = None;
            let mut j = start;
            while j + 1 < bytes.len() {
                if &bytes[j..j + 2] == b"}}" {
                    end = Some(j);
                    break;
                }
                j += 1;
            }
            let end = end.ok_or_else(|| {
                anyhow::anyhow!(
                    "unclosed `{{{{` in `{s}` — use `\\{{{{...}}}}` to keep a literal"
                )
            })?;
            let name = s[start..end].trim();
            let value = resolve_var(name, vars)?;
            out.push_str(&value);
            i = end + 2;
            continue;
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    Ok(out)
}

fn resolve_var(name: &str, vars: &VarMap) -> anyhow::Result<String> {
    if let Some(env_key) = name.strip_prefix("env.") {
        return std::env::var(env_key)
            .map_err(|_| anyhow::anyhow!("env var `{env_key}` is not set"));
    }
    if let Some(v) = vars.get(name) {
        return Ok(v.clone());
    }
    let mut known: Vec<&str> = vars.keys().map(|s| s.as_str()).collect();
    known.sort();
    let list = if known.is_empty() {
        "(no vars defined — add `vars {{ name \"value\" }}` at the top of the file, or use `env.NAME`)".to_string()
    } else {
        format!("known: {}", known.join(", "))
    };
    anyhow::bail!("unknown variable `{{{{{name}}}}}`. {list}")
}

/// A single ingredient in a recipe.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Step {
    pub id: String,
    #[serde(default)]
    pub enabled: bool,
    /// Optional handwritten-style note that renders in the margin.
    #[serde(default)]
    pub note: Option<String>,
    /// What to do if this step errors at runtime. Default `stop` halts
    /// the workflow (prior behaviour); `continue` logs the failure and
    /// moves on.
    #[serde(default)]
    pub on_error: OnError,
    pub action: Action,
}

impl Step {
    pub fn new(action: Action) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            enabled: true,
            note: None,
            on_error: OnError::default(),
            action,
        }
    }
}

/// Per-step error policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum OnError {
    /// Halt the workflow immediately. Default.
    #[default]
    Stop,
    /// Log the error, report the step as failed, keep running.
    Continue,
}

/// A binding that fires the workflow on an external event. AHK-style
/// hotkeys today; hotstrings, file-watch, schedule, and per-window
/// conditions land in later releases. The runner ignores triggers
/// (workflows still execute via GUI / CLI / library card the same way
/// they always have); the v0.4 daemon is what actually subscribes to
/// the configured triggers and dispatches workflows on activation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Trigger {
    pub kind: TriggerKind,
    /// Optional context predicate. v0.5 and later — the daemon gates
    /// activation on whether the condition holds at fire time. v0.4
    /// parses the field but doesn't act on it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub when: Option<TriggerCondition>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum TriggerKind {
    /// Global keyboard chord, AHK-style. e.g. "ctrl+alt+d".
    Chord { chord: String },
    /// Text-expansion trigger. The user types `text`; the daemon
    /// backspaces it out and runs the workflow body. v0.5+.
    Hotstring { text: String },
}

/// Per-trigger context predicate. Mirrors the structure of the
/// existing `Condition` enum on workflow-level when/unless blocks.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum TriggerCondition {
    /// Window class (Wayland app_id) substring match, case-insensitive.
    WindowClass { class: String },
    /// Window title substring match, case-insensitive.
    WindowTitle { title: String },
}

/// The recipe itself.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Workflow {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub subtitle: Option<String>,
    #[serde(default)]
    pub steps: Vec<Step>,
    /// User-defined workflow-level variables, substituted into string
    /// args at run time as `{{name}}`. Also overridable via CLI.
    #[serde(default)]
    pub vars: std::collections::BTreeMap<String, String>,
    /// Named imports — maps short name → fragment-file path. Resolved
    /// at decode time by `kdl_format::expand_imports` when the step
    /// tree contains `Action::Use { name }`. Empty after the file
    /// loader has expanded uses against it, but the GUI re-populates
    /// it through the imports dialog and round-trips it back through
    /// JSON ↔ KDL on save.
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub imports: std::collections::BTreeMap<String, String>,
    /// Triggers that fire this workflow. Empty for hand-launched
    /// workflows; populated for ones the daemon should bind. Not yet
    /// wired into a daemon as of v0.3.x — parsing only.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub triggers: Vec<Trigger>,
    #[serde(default)]
    pub created: Option<chrono::DateTime<chrono::Utc>>,
    #[serde(default)]
    pub modified: Option<chrono::DateTime<chrono::Utc>>,
    #[serde(default)]
    pub last_run: Option<chrono::DateTime<chrono::Utc>>,
    /// Visual annotation rectangles drawn behind the step cards on
    /// the canvas — purely cosmetic, the engine ignores them.
    /// Persisted in KDL alongside steps so a workflow's visual
    /// layout survives reopening.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub groups: Vec<Group>,
    /// Folder this workflow lives in, derived from the .kdl file's
    /// parent directory relative to the workflows root. None for
    /// top-level files. Not serialised — it's a filesystem fact,
    /// not workflow content.
    #[serde(skip, default)]
    pub folder: Option<String>,
}

/// A coloured rounded-rectangle annotation drawn behind step cards
/// on the canvas. Used to visually group steps ("the build half",
/// "the deploy half"). Has no semantics — the engine treats them as
/// decoration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Group {
    pub id: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    /// Named tint key from a fixed palette. Recognised values mirror
    /// the category palette plus a few muted neutrals; the GUI
    /// resolves the name to an actual hex color. Unrecognised names
    /// fall back to the accent palette.
    #[serde(default = "default_group_color")]
    pub color: String,
    /// Free-form annotation rendered in the rectangle's upper-left.
    #[serde(default)]
    pub comment: String,
}

fn default_group_color() -> String {
    "accent".to_string()
}

impl Workflow {
    pub fn new(title: impl Into<String>) -> Self {
        let now = chrono::Utc::now();
        Self {
            id: Uuid::new_v4().to_string(),
            title: title.into(),
            subtitle: None,
            steps: Vec::new(),
            vars: Default::default(),
            imports: Default::default(),
            triggers: Vec::new(),
            groups: Vec::new(),
            created: Some(now),
            modified: Some(now),
            last_run: None,
            folder: None,
        }
    }
}

/// Every kind of thing a step can do.
///
/// Tagged union: serializes to `{ "kind": "wdo_type", "text": "hello", ... }`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Action {
    // ------------------------------ Input (wdotool) ---------------------
    /// Type unicode text via wdotool.
    WdoType {
        text: String,
        /// Per-character delay in ms.
        #[serde(default)]
        delay_ms: Option<u32>,
    },
    /// Send a key or chord (e.g. `ctrl+shift+a`, `Return`).
    WdoKey {
        chord: String,
        #[serde(default)]
        clear_modifiers: bool,
    },
    /// Press a key or chord and hold it until a matching `key-up` runs.
    /// Handy for building chords manually or long-press.
    WdoKeyDown { chord: String },
    /// Release a previously pressed key or chord.
    WdoKeyUp { chord: String },
    /// Mouse click. Buttons: 1=left, 2=middle, 3=right, 8=back, 9=forward.
    WdoClick { button: u8 },
    /// Press a mouse button and hold it. Pair with `mouse-up` to complete
    /// a drag (with `move` steps in between).
    WdoMouseDown { button: u8 },
    /// Release a previously pressed mouse button.
    WdoMouseUp { button: u8 },
    /// Move the cursor.
    WdoMouseMove {
        x: i32,
        y: i32,
        #[serde(default)]
        relative: bool,
    },
    /// Scroll. dy positive = down.
    WdoScroll { dx: i32, dy: i32 },
    /// Activate a window by name substring (wlroots/kde only on wdotool).
    WdoActivateWindow { name: String },
    /// Block until a window matching `name` exists or `timeout_ms` elapses.
    /// The counterpart to Delay for event-driven waits — the difference
    /// between a reliable replay and a racy one.
    WdoAwaitWindow {
        name: String,
        #[serde(default = "default_await_timeout_ms")]
        timeout_ms: u64,
    },

    // ------------------------------ System -------------------------------
    /// Wait.
    Delay { ms: u64 },
    /// Run a shell command. Output is captured as the step result.
    Shell {
        command: String,
        #[serde(default)]
        shell: Option<String>, // defaults to $SHELL or /bin/sh
        /// If set, the shell's stdout is captured into a variable of
        /// this name, substitutable as `{{name}}` in later steps.
        #[serde(default)]
        capture_as: Option<String>,
        /// Per-step wall-clock timeout. On elapse the child is killed
        /// and the step errors instead of hanging the workflow.
        /// `None` = no limit (inherit prior behaviour).
        #[serde(default)]
        timeout_ms: Option<u64>,
        /// Retry the command up to `retries` extra times on failure.
        /// Default 0 (no retry).
        #[serde(default)]
        retries: u32,
        /// Sleep `backoff_ms` between retries. Default 500ms when
        /// `retries > 0` and not specified.
        #[serde(default)]
        backoff_ms: Option<u64>,
    },
    /// Send a desktop notification via `notify-send`.
    Notify {
        title: String,
        #[serde(default)]
        body: Option<String>,
    },
    /// Copy text to the clipboard (via wl-copy).
    Clipboard { text: String },

    // ------------------------------ Comment / divider --------------------
    /// Pure annotation. Never executes.
    Note { text: String },

    // ------------------------------ Flow control -------------------------
    /// Repeat a nested sequence of steps `count` times. Expanded at
    /// dispatch time so inner steps emit per-iteration signals; the
    /// KDL round-trip keeps the block form.
    Repeat {
        count: u32,
        steps: Vec<Step>,
    },
    /// Conditionally run a nested sequence. Condition is evaluated at
    /// dispatch time (not pre-run) so it can reference state created
    /// by earlier steps in the same workflow. `negate=true` implements
    /// `unless`.
    Conditional {
        cond: Condition,
        #[serde(default)]
        negate: bool,
        steps: Vec<Step>,
    },
    /// Splice-in a named import declared in the workflow's top-level
    /// `imports { ... }` block. Expanded at decode time against the
    /// imports map by `kdl_format::expand_imports`, so the engine
    /// never sees this variant at dispatch.
    Use { name: String },
}

/// A predicate over external state, tested at dispatch time.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Condition {
    /// A window whose title contains `name` is currently present.
    Window { name: String },
    /// The given filesystem path exists (file, dir, or symlink to either).
    /// Leading `~/` is expanded against $HOME.
    File { path: String },
    /// The named environment variable is set and non-empty. If `equals`
    /// is given, also require the value match exactly.
    Env {
        name: String,
        #[serde(default)]
        equals: Option<String>,
    },
}

impl Action {
    /// Category label, rendered small-caps in the UI. Mirrored on the
    /// frontend side for now (keep in sync with `categoryOf` in types.ts);
    /// a future wflow-engine consumer will use this Rust-side path.
    #[allow(dead_code)]
    pub fn category(&self) -> &'static str {
        match self {
            Action::WdoType { .. } => "type",
            Action::WdoKey { .. } => "key",
            Action::WdoKeyDown { .. } => "key",
            Action::WdoKeyUp { .. } => "key",
            Action::WdoClick { .. } => "click",
            Action::WdoMouseDown { .. } => "click",
            Action::WdoMouseUp { .. } => "click",
            Action::WdoMouseMove { .. } => "move",
            Action::WdoScroll { .. } => "scroll",
            Action::WdoActivateWindow { .. } => "focus",
            Action::WdoAwaitWindow { .. } => "wait",
            Action::Delay { .. } => "wait",
            Action::Shell { .. } => "shell",
            Action::Notify { .. } => "notify",
            Action::Clipboard { .. } => "clipboard",
            Action::Note { .. } => "note",
            Action::Repeat { .. } => "repeat",
            Action::Conditional { negate: false, .. } => "when",
            Action::Conditional { negate: true, .. } => "unless",
            Action::Use { .. } => "use",
        }
    }

    /// Human-readable one-line description. Used by the CLI for `list`,
    /// `show`, and per-step progress in `run`. Kept here so the format
    /// stays consistent across commands.
    pub fn describe(&self) -> String {
        match self {
            Action::WdoType { text, .. } => format!("type {}", quote_short(text)),
            Action::WdoKey { chord, .. } => format!("key {chord}"),
            Action::WdoKeyDown { chord } => format!("key-down {chord}"),
            Action::WdoKeyUp { chord } => format!("key-up {chord}"),
            Action::WdoClick { button } => format!("click button {button}"),
            Action::WdoMouseDown { button } => format!("mouse-down button {button}"),
            Action::WdoMouseUp { button } => format!("mouse-up button {button}"),
            Action::WdoMouseMove { x, y, relative } => {
                if *relative {
                    format!("move +{x},+{y}")
                } else {
                    format!("move {x},{y}")
                }
            }
            Action::WdoScroll { dx, dy } => format!("scroll dx={dx} dy={dy}"),
            Action::WdoActivateWindow { name } => format!("focus {}", quote_short(name)),
            Action::WdoAwaitWindow { name, timeout_ms } => format!(
                "wait-window {} (timeout {})",
                quote_short(name),
                fmt_duration_ms(*timeout_ms)
            ),
            Action::Delay { ms } => format!("wait {}", fmt_duration_ms(*ms)),
            Action::Shell { command, .. } => format!("shell {}", quote_short(command)),
            Action::Notify { title, body } => match body {
                Some(b) if !b.is_empty() => {
                    format!("notify {} — {}", quote_short(title), quote_short(b))
                }
                _ => format!("notify {}", quote_short(title)),
            },
            Action::Clipboard { text } => format!("clipboard {}", quote_short(text)),
            Action::Note { text } => format!("note {}", quote_short(text)),
            Action::Repeat { count, steps } => format!(
                "repeat {count}× ({} step{})",
                steps.len(),
                if steps.len() == 1 { "" } else { "s" }
            ),
            Action::Conditional { cond, negate, steps } => {
                let verb = if *negate { "unless" } else { "when" };
                format!(
                    "{verb} {} ({} step{})",
                    cond.describe(),
                    steps.len(),
                    if steps.len() == 1 { "" } else { "s" }
                )
            }
            Action::Use { name } => format!("use {name}"),
        }
    }
}

impl Condition {
    pub fn describe(&self) -> String {
        match self {
            Condition::Window { name } => format!("window={}", quote_short(name)),
            Condition::File { path } => format!("file={}", quote_short(path)),
            Condition::Env { name, equals: None } => format!("env.{name}"),
            Condition::Env { name, equals: Some(v) } => {
                format!("env.{name}={}", quote_short(v))
            }
        }
    }
}

/// Short human duration, used in `describe()`. 500 → "500ms", 1500 → "1.5s",
/// 90000 → "90s", 3600000 → "60m".
pub fn fmt_duration_ms(ms: u64) -> String {
    if ms < 1_000 {
        format!("{ms}ms")
    } else if ms < 60_000 {
        let secs = ms as f64 / 1_000.0;
        if (secs - secs.round()).abs() < 0.05 {
            format!("{}s", secs.round() as u64)
        } else {
            format!("{secs:.1}s")
        }
    } else if ms < 3_600_000 {
        format!("{}m", ms / 60_000)
    } else {
        format!("{}h", ms / 3_600_000)
    }
}

fn quote_short(s: &str) -> String {
    const MAX: usize = 64;
    let single_line = s.replace('\n', " ↵ ");
    let mut trimmed = single_line.as_str();
    let mut truncated = String::new();
    if single_line.chars().count() > MAX {
        truncated = single_line.chars().take(MAX).collect::<String>();
        truncated.push('…');
        trimmed = truncated.as_str();
    }
    format!("\"{trimmed}\"")
}

/// What happened when a step ran. Streamed to the frontend per-step.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum StepOutcome {
    Ok {
        #[serde(default)]
        output: Option<String>,
        duration_ms: u64,
    },
    Skipped {
        reason: String,
    },
    Error {
        message: String,
        duration_ms: u64,
    },
}

/// Event emitted to the frontend during a workflow run.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RunEvent {
    Started {
        workflow_id: String,
        run_id: String,
    },
    StepStart {
        step_id: String,
        index: usize,
    },
    StepDone {
        step_id: String,
        index: usize,
        outcome: StepOutcome,
    },
    /// Emitted while the engine is awaiting a debug command between
    /// steps. `index` is the step that's about to run, not the one
    /// just completed; the UI uses this to pulse the upcoming card
    /// and flip the run/step buttons into their paused state.
    Paused {
        index: usize,
    },
    Finished {
        run_id: String,
        ok: bool,
    },
}
