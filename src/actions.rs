//! Workflow = ordered Steps. Step wraps Action + per-step metadata
//! (id, note, enabled, on_error).
//!
//! New action kind = new variant + arm in `engine::run_action` + QML
//! delegate. Nothing else branches on action kind.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

fn default_await_timeout_ms() -> u64 {
    5_000
}

// Key-name normalization.

/// Maps friendly aliases to the X11 keysyms wdotool wants. Applied at
/// decode time so the on-disk form is what wdotool will execute.
/// Unknown names pass through; users can always write a wdotool keysym.
pub fn normalize_chord(raw: &str) -> String {
    raw.split('+')
        .map(str::trim)
        .map(normalize_key_segment)
        .collect::<Vec<_>>()
        .join("+")
}

fn normalize_key_segment(part: &str) -> String {
    // Case-insensitive; user case survives for anything not in the table.
    let lower = part.to_ascii_lowercase();
    match lower.as_str() {
        "ctrl" | "control" => "ctrl".into(),
        "shift" => "shift".into(),
        "alt" => "alt".into(),
        "super" => "super".into(),
        "cmd" | "command" | "win" | "windows" | "meta" => "super".into(),
        "option" | "opt" => "alt".into(),
        "enter" | "return" => "Return".into(),
        "esc" | "escape" => "Escape".into(),
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

// Template substitution.

/// Variable map threaded through a run. Seeded from `vars { }`; shell
/// steps with `as="foo"` extend it.
pub type VarMap = std::collections::BTreeMap<String, String>;

/// `{{name}}` → vars[name] | `env.NAME` → process env. `\{{...}}`
/// keeps the literal.
pub fn substitute(s: &str, vars: &VarMap) -> anyhow::Result<String> {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && bytes.get(i + 1..i + 3) == Some(b"{{") {
            out.push_str("{{");
            i += 3;
            continue;
        }
        if bytes.get(i..i + 2) == Some(b"{{") {
            let start = i + 2;
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
                    "unclosed `{{{{` in `{s}`, use `\\{{{{...}}}}` to keep a literal"
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
        "(no vars defined, add `vars {{ name \"value\" }}` at the top of the file, or use `env.NAME`)".to_string()
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
    /// `stop` halts the run; `continue` logs and moves on.
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum OnError {
    #[default]
    Stop,
    Continue,
}

/// External event that fires the workflow. The runner ignores these;
/// `wflow daemon` is what subscribes and dispatches.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Trigger {
    pub kind: TriggerKind,
    /// Daemon binds the chord globally (Wayland has no per-window
    /// grabs); `wflow trigger-fire` probes the focused window per fire.
    /// Hyprland and Sway probe today; portal-bound DEs fire ungated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub when: Option<TriggerCondition>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum TriggerKind {
    /// e.g. "ctrl+alt+d".
    Chord { chord: String },
    /// v0.5+. Daemon backspaces `text` out and fires the workflow.
    Hotstring { text: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum TriggerCondition {
    /// Wayland app_id substring match, case-insensitive.
    WindowClass { class: String },
    /// Window title substring match, case-insensitive.
    WindowTitle { title: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Workflow {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub subtitle: Option<String>,
    #[serde(default)]
    pub steps: Vec<Step>,
    /// `{{name}}` substitution at run time. Overridable via CLI.
    #[serde(default)]
    pub vars: std::collections::BTreeMap<String, String>,
    /// `name → fragment-path`. Resolved by `kdl_format::expand_imports`
    /// when the step tree carries `Action::Use { name }`.
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub imports: std::collections::BTreeMap<String, String>,
    /// Empty for hand-launched workflows, populated for daemon-bound ones.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub triggers: Vec<Trigger>,
    #[serde(default)]
    pub created: Option<chrono::DateTime<chrono::Utc>>,
    #[serde(default)]
    pub modified: Option<chrono::DateTime<chrono::Utc>>,
    #[serde(default)]
    pub last_run: Option<chrono::DateTime<chrono::Utc>>,
    /// Decorative canvas rectangles. Engine ignores them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub groups: Vec<Group>,
    /// Filesystem fact, not workflow content; not serialised.
    #[serde(skip, default)]
    pub folder: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Group {
    pub id: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    /// Tint key from the category palette plus a few muted neutrals;
    /// unknown names fall back to accent.
    #[serde(default = "default_group_color")]
    pub color: String,
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

/// Tagged union; serializes to `{"kind": "wdo_type", ...}`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Action {
    // Input (wdotool).
    WdoType {
        text: String,
        #[serde(default)]
        delay_ms: Option<u32>,
    },
    /// e.g. `ctrl+shift+a`, `Return`.
    WdoKey {
        chord: String,
        #[serde(default)]
        clear_modifiers: bool,
    },
    /// Press and hold; pair with `key-up`.
    WdoKeyDown { chord: String },
    WdoKeyUp { chord: String },
    /// 1=left, 2=middle, 3=right, 8=back, 9=forward.
    WdoClick { button: u8 },
    /// Press and hold; pair with `mouse-up`.
    WdoMouseDown { button: u8 },
    WdoMouseUp { button: u8 },
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
    /// The counterpart to Delay for event-driven waits, the difference
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
        #[serde(default)]
        capture_as: Option<String>,
        /// `None` = no timeout. On elapse the child is killed.
        #[serde(default)]
        timeout_ms: Option<u64>,
        #[serde(default)]
        retries: u32,
        /// Default 500ms when retries > 0 and unset.
        #[serde(default)]
        backoff_ms: Option<u64>,
    },
    /// notify-send.
    Notify {
        title: String,
        #[serde(default)]
        body: Option<String>,
    },
    /// wl-copy.
    Clipboard { text: String },

    /// Pure annotation, never executes.
    Note { text: String },

    /// Expanded at dispatch so inner steps emit per-iteration signals.
    Repeat {
        count: u32,
        steps: Vec<Step>,
    },
    /// `negate=true` is `unless`. `else_steps` runs when `steps` is skipped.
    Conditional {
        cond: Condition,
        #[serde(default)]
        negate: bool,
        steps: Vec<Step>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        else_steps: Vec<Step>,
    },
    /// Resolved at decode time against the workflow's imports map.
    /// The engine never sees this variant.
    Use { name: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Condition {
    /// A window whose title contains `name` is present.
    Window { name: String },
    /// Path exists. Leading `~/` expands against $HOME.
    File { path: String },
    /// Env var is set and non-empty. `equals` matches exactly.
    Env {
        name: String,
        #[serde(default)]
        equals: Option<String>,
    },
}

impl Action {
    /// Category label rendered small-caps in the UI. Mirror on the
    /// QML side via `categoryOf` in types.ts.
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

    /// One-line description. Shared by CLI list / show / run output.
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
                    format!("notify {}, {}", quote_short(title), quote_short(b))
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
            Action::Conditional { cond, negate, steps, else_steps } => {
                let verb = if *negate { "unless" } else { "when" };
                let then_part = format!(
                    "{verb} {} ({} step{})",
                    cond.describe(),
                    steps.len(),
                    if steps.len() == 1 { "" } else { "s" }
                );
                if else_steps.is_empty() {
                    then_part
                } else {
                    format!(
                        "{then_part} else ({} step{})",
                        else_steps.len(),
                        if else_steps.len() == 1 { "" } else { "s" }
                    )
                }
            }
            Action::Use { name } => format!("use {name}"),
        }
    }
}

/// Value column for chip trails (Explore detail, catalog cards,
/// library cards). Kept here so every surface agrees.
pub fn step_value_label(action: &Action) -> String {
    match action {
        Action::WdoType { text, .. } => text.clone(),
        Action::WdoKey { chord, .. } => chord.clone(),
        Action::WdoKeyDown { chord } => chord.clone(),
        Action::WdoKeyUp { chord } => chord.clone(),
        Action::WdoClick { button } => format!("button {button}"),
        Action::WdoMouseDown { button } => format!("button {button}"),
        Action::WdoMouseUp { button } => format!("button {button}"),
        Action::WdoMouseMove { x, y, relative } => {
            if *relative {
                format!("+{x}, +{y}")
            } else {
                format!("{x}, {y}")
            }
        }
        Action::WdoScroll { dx, dy } => format!("dx {dx}, dy {dy}"),
        Action::WdoActivateWindow { name } => name.clone(),
        Action::WdoAwaitWindow { name, timeout_ms } => {
            format!("{name} (≤{})", fmt_duration_ms(*timeout_ms))
        }
        Action::Delay { ms } => fmt_duration_ms(*ms),
        Action::Shell { command, .. } => command.clone(),
        Action::Notify { title, body } => match body {
            Some(b) if !b.is_empty() => format!("{title}, {b}"),
            _ => title.clone(),
        },
        Action::Clipboard { text } => text.clone(),
        Action::Note { text } => text.clone(),
        Action::Repeat { count, steps } => format!(
            "{count}× ({} step{})",
            steps.len(),
            if steps.len() == 1 { "" } else { "s" }
        ),
        Action::Conditional { cond, negate, steps, else_steps } => {
            let verb = if *negate { "unless" } else { "when" };
            let cond_s = match cond {
                Condition::Window { name } => format!("window={name}"),
                Condition::File { path } => format!("file={path}"),
                Condition::Env { name, equals: None } => format!("env.{name}"),
                Condition::Env { name, equals: Some(v) } => format!("env.{name}={v}"),
            };
            let total = steps.len() + else_steps.len();
            format!(
                "{verb} {cond_s} ({total} step{})",
                if total == 1 { "" } else { "s" }
            )
        }
        Action::Use { name } => name.clone(),
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

/// 500 → "500ms", 1500 → "1.5s", 90000 → "90s", 3600000 → "60m".
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
    let trimmed = if single_line.chars().count() > MAX {
        let mut truncated: String = single_line.chars().take(MAX).collect();
        truncated.push('…');
        truncated
    } else {
        single_line
    };
    format!("\"{trimmed}\"")
}

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
    /// `index` is the upcoming step, not the just-completed one.
    Paused {
        index: usize,
    },
    Finished {
        run_id: String,
        ok: bool,
    },
}
