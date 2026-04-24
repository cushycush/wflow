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

/// A single ingredient in a recipe.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Step {
    pub id: String,
    #[serde(default)]
    pub enabled: bool,
    /// Optional handwritten-style note that renders in the margin.
    #[serde(default)]
    pub note: Option<String>,
    pub action: Action,
}

impl Step {
    pub fn new(action: Action) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            enabled: true,
            note: None,
            action,
        }
    }
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
    #[serde(default)]
    pub created: Option<chrono::DateTime<chrono::Utc>>,
    #[serde(default)]
    pub modified: Option<chrono::DateTime<chrono::Utc>>,
    #[serde(default)]
    pub last_run: Option<chrono::DateTime<chrono::Utc>>,
}

impl Workflow {
    pub fn new(title: impl Into<String>) -> Self {
        let now = chrono::Utc::now();
        Self {
            id: Uuid::new_v4().to_string(),
            title: title.into(),
            subtitle: None,
            steps: Vec::new(),
            created: Some(now),
            modified: Some(now),
            last_run: None,
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
    /// Mouse click. Buttons: 1=left, 2=middle, 3=right, 8=back, 9=forward.
    WdoClick { button: u8 },
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
            Action::WdoClick { .. } => "click",
            Action::WdoMouseMove { .. } => "move",
            Action::WdoScroll { .. } => "scroll",
            Action::WdoActivateWindow { .. } => "focus",
            Action::WdoAwaitWindow { .. } => "wait",
            Action::Delay { .. } => "wait",
            Action::Shell { .. } => "shell",
            Action::Notify { .. } => "notify",
            Action::Clipboard { .. } => "clipboard",
            Action::Note { .. } => "note",
        }
    }

    /// Human-readable one-line description. Used by the CLI for `list`,
    /// `show`, and per-step progress in `run`. Kept here so the format
    /// stays consistent across commands.
    pub fn describe(&self) -> String {
        match self {
            Action::WdoType { text, .. } => format!("type {}", quote_short(text)),
            Action::WdoKey { chord, .. } => format!("key {chord}"),
            Action::WdoClick { button } => format!("click button {button}"),
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
    Finished {
        run_id: String,
        ok: bool,
    },
}
