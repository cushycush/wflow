//! Trigger backends. Register a `Trigger` from a workflow with the
//! compositor / portal so the user's chord activates it.
//!
//! Today: Hyprland and Sway IPC. The GlobalShortcuts portal (KDE 6,
//! GNOME 46+) lands next; it's what gates the AHK-positioned launch
//! since it covers the majority of the audience.

pub mod hyprland;
pub mod portal;
pub mod sway;

use crate::actions::{Trigger, TriggerKind};

/// Pick a backend for the current session. Returns None when no
/// backend recognizes the environment. Caller falls back to the
/// dry-run path so users at least see what WOULD bind.
pub fn detect() -> Option<Box<dyn Backend>> {
    if hyprland::is_available() {
        return Some(Box::new(hyprland::HyprlandBackend::new()));
    }
    if sway::is_available() {
        return Some(Box::new(sway::SwayBackend::new()));
    }
    None
}

/// One bound trigger. Carries everything the daemon needs to
/// register / unregister it and to dispatch the workflow when the
/// chord fires.
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

/// Backend trait. A backend translates a `Binding` into a
/// compositor-specific bind / unbind request. The daemon owns a
/// single backend instance for the session and registers every
/// trigger through it.
pub trait Backend: Send {
    fn name(&self) -> &'static str;

    /// Register one binding. Hyprland implementation: send a
    /// `keyword bind = MODS, KEY, exec, wflow run <id> --yes`
    /// request to the per-instance socket.
    fn bind(&mut self, b: &Binding) -> anyhow::Result<()>;

    /// Remove one binding by chord. Called on daemon shutdown so
    /// hotkeys don't outlive the daemon process. Hyprland: `keyword
    /// unbind = MODS, KEY`.
    fn unbind(&mut self, b: &Binding) -> anyhow::Result<()>;
}
