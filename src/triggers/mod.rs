//! Trigger backends — register a `Trigger` from a workflow with the
//! compositor / portal so the user's chord activates it.
//!
//! Today: Hyprland IPC only. Sway IPC, KWin scripting, GNOME Shell
//! extension, and the GlobalShortcuts portal land in v0.5+ as the
//! audience hits them.

pub mod hyprland;

use crate::actions::{Trigger, TriggerKind};

/// Pick a backend for the current session. Returns None when no
/// backend recognizes the environment — caller falls back to the
/// dry-run path so users at least see what WOULD bind.
pub fn detect() -> Option<Box<dyn Backend>> {
    if hyprland::is_available() {
        return Some(Box::new(hyprland::HyprlandBackend::new()));
    }
    None
}

#[derive(Debug, Clone)]
pub struct Binding {
    pub workflow_id: String,
    pub workflow_title: String,
    pub trigger: Trigger,
}

impl Binding {
    /// Skip non-chord triggers for now (hotstrings need a global
    /// keyboard monitor, not a compositor binding) and skip chord
    /// triggers with a `when` predicate (the compositor binds
    /// globally; per-window gating ships in v0.5 alongside Sway /
    /// KDE / GNOME backends).
    pub fn is_dispatchable_today(&self) -> bool {
        matches!(self.trigger.kind, TriggerKind::Chord { .. })
    }
}

pub trait Backend: Send {
    fn name(&self) -> &'static str;

    fn bind(&mut self, b: &Binding) -> anyhow::Result<()>;

    /// Called on shutdown so hotkeys don't outlive the daemon.
    fn unbind(&mut self, b: &Binding) -> anyhow::Result<()>;
}
