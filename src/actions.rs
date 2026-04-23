//! Workflow = ordered Steps. Step wraps Action + per-step metadata
//! (id, note, enabled, on_error).
//!
//! New action kind = new variant + arm in `engine::run_action` + QML
//! delegate. Nothing else branches on action kind.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

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
    /// 1=left, 2=middle, 3=right, 8=back, 9=forward.
    WdoClick { button: u8 },
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

    // ------------------------------ System -------------------------------
    /// Wait.
    Delay { ms: u64 },
    /// Run a shell command. Output is captured as the step result.
    Shell {
        command: String,
        #[serde(default)]
        shell: Option<String>, // defaults to $SHELL or /bin/sh
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
}

impl Action {
    /// Category label rendered small-caps in the UI. Mirror on the
    /// QML side via `categoryOf` in types.ts.
    #[allow(dead_code)]
    pub fn category(&self) -> &'static str {
        match self {
            Action::WdoType { .. } => "type",
            Action::WdoKey { .. } => "key",
            Action::WdoClick { .. } => "click",
            Action::WdoMouseMove { .. } => "move",
            Action::WdoScroll { .. } => "scroll",
            Action::WdoActivateWindow { .. } => "focus",
            Action::Delay { .. } => "wait",
            Action::Shell { .. } => "shell",
            Action::Notify { .. } => "notify",
            Action::Clipboard { .. } => "clipboard",
            Action::Note { .. } => "note",
        }
    }

    /// One-line description. Shared by CLI list / show / run output.
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
            Action::Delay { ms } => format!("wait {ms}ms"),
            Action::Shell { command, .. } => format!("shell {}", quote_short(command)),
            Action::Notify { title, body } => match body {
                Some(b) if !b.is_empty() => {
                    format!("notify {}, {}", quote_short(title), quote_short(b))
                }
                _ => format!("notify {}", quote_short(title)),
            },
            Action::Clipboard { text } => format!("clip {}", quote_short(text)),
            Action::Note { text } => format!("note {}", quote_short(text)),
        }
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
    Finished {
        run_id: String,
        ok: bool,
    },
}
