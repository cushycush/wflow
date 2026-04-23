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
            Action::Delay { .. } => "wait",
            Action::Shell { .. } => "shell",
            Action::Notify { .. } => "notify",
            Action::Clipboard { .. } => "clipboard",
            Action::Note { .. } => "note",
        }
    }
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
