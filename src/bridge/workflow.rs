//! WorkflowController — the currently-open workflow.
//!
//! Loads a workflow by id, exposes its JSON to QML for read + edit,
//! persists back to disk, and runs the engine on a background tokio
//! task that posts per-step updates back onto the Qt thread.

use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;

use cxx_qt::Threading;
use cxx_qt_lib::QString;

use crate::actions::{RunEvent, StepOutcome, Workflow};
use crate::{engine, kdl_format, security, store};

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
    }

    unsafe extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[qproperty(QString, workflow_json)]
        #[qproperty(i32, active_step)]
        #[qproperty(QString, active_step_id)]
        #[qproperty(bool, running)]
        #[qproperty(bool, paused)]
        #[qproperty(QString, last_error)]
        type WorkflowController = super::WorkflowControllerRust;

        /// Load a workflow from disk into `workflow_json`.
        #[qinvokable]
        fn load(self: Pin<&mut WorkflowController>, id: QString);

        /// Load a fragment file from an absolute path, wrapped in a
        /// synthesized read-only Workflow so the rest of the editor
        /// can render it through the same bindings as a normal
        /// workflow. The synthetic id is `fragment:<abspath>`; the
        /// title is the file's basename. `use` calls inside the
        /// fragment are not expanded — they render as-is so the
        /// user can click further into them.
        #[qinvokable]
        fn load_fragment(self: Pin<&mut WorkflowController>, path: QString);

        /// Resolve an `imports[name]` entry to an absolute filesystem
        /// path, taking the current workflow's directory as the base
        /// for relative paths. Returns "" if the workflow_json is
        /// invalid, the name is missing from the imports map, or the
        /// resolved path can't be canonicalised. Used by the GUI to
        /// open the target of a `use NAME` card in a fragment tab.
        #[qinvokable]
        fn resolve_import_path(
            self: Pin<&mut WorkflowController>,
            name: QString,
        ) -> QString;

        /// Save a workflow passed in as JSON text.
        /// Returns the id the workflow was saved under (== input's id).
        #[qinvokable]
        fn save(self: Pin<&mut WorkflowController>, json: QString) -> QString;

        /// Save a fragment file. Takes the synthesized workflow JSON
        /// the editor has been mutating + the absolute path the
        /// fragment was loaded from, extracts the steps array, and
        /// writes the bare-fragment KDL form back to disk. The
        /// workflow's id / title / subtitle / imports map etc. are
        /// dropped — they were only synthetic wrapper to feed the
        /// editor; the on-disk fragment is just step nodes. Returns
        /// the path on success, "" on failure (last_error is set).
        #[qinvokable]
        fn save_fragment(
            self: Pin<&mut WorkflowController>,
            path: QString,
            json: QString,
        ) -> QString;

        /// Run the current workflow. Returns immediately. If the
        /// workflow file is trusted (see src/security.rs), progress is
        /// surfaced via step_done / run_finished signals and the
        /// active_step / running properties. If the file is untrusted,
        /// `trust_prompt_required` fires instead and the engine waits
        /// for a `confirm_trust` or `cancel_trust` call before
        /// proceeding.
        #[qinvokable]
        fn run(self: Pin<&mut WorkflowController>);

        /// Run in debug mode. Same as `run` but the engine pauses
        /// before each step and waits for `step_next`,
        /// `continue_run`, or `stop_run` to advance. Emits the same
        /// trust prompt for untrusted workflows.
        #[qinvokable]
        fn run_debug(self: Pin<&mut WorkflowController>);

        /// Advance one step in a debug session. No-op when not paused.
        #[qinvokable]
        fn step_next(self: Pin<&mut WorkflowController>);

        /// Resume a debug session, running the rest of the workflow
        /// without pausing.
        #[qinvokable]
        fn continue_run(self: Pin<&mut WorkflowController>);

        /// Halt the running workflow (debug or normal).
        #[qinvokable]
        fn stop_run(self: Pin<&mut WorkflowController>);

        /// Confirm a pending untrusted-workflow run. Marks the file
        /// trusted on disk and starts the engine.
        #[qinvokable]
        fn confirm_trust(self: Pin<&mut WorkflowController>);

        /// Cancel a pending untrusted-workflow run. Clears the pending
        /// state without marking trusted; the engine never starts.
        #[qinvokable]
        fn cancel_trust(self: Pin<&mut WorkflowController>);

        /// Signalled after each step completes.
        /// `status` is one of "ok" | "skipped" | "error". `step_id`
        /// is the action's stable id — needed by the canvas to attach
        /// status dots to inner steps that don't have a corresponding
        /// flat-index card (repeat children).
        #[qsignal]
        fn step_done(
            self: Pin<&mut WorkflowController>,
            index: i32,
            step_id: QString,
            status: QString,
            message: QString,
        );

        /// Signalled when the engine begins a step. Carries the same
        /// id/index the active_step / active_step_id qproperties also
        /// receive, but as an unconditional signal — `set_active_step_id`
        /// dedupes when the same id is set across iterations of a
        /// `repeat`, which means QML never sees a binding change. This
        /// signal fires every time so the inner-step pulse animation
        /// can restart per iteration.
        #[qsignal]
        fn step_started(
            self: Pin<&mut WorkflowController>,
            index: i32,
            step_id: QString,
        );

        /// Signalled once the workflow finishes (or errors out).
        #[qsignal]
        fn run_finished(self: Pin<&mut WorkflowController>, ok: bool);

        /// Signalled when the user clicks Run on a workflow that
        /// hasn't been trusted on this machine yet. `summary` is a
        /// multi-line human-readable description of what the workflow
        /// will execute — QML displays it verbatim in a dialog so the
        /// user can review before confirming. The engine waits for
        /// `confirm_trust` or `cancel_trust` before doing anything.
        #[qsignal]
        fn trust_prompt_required(
            self: Pin<&mut WorkflowController>,
            summary: QString,
        );
    }

    impl cxx_qt::Threading for WorkflowController {}
}

pub struct WorkflowControllerRust {
    pub workflow_json: QString,
    pub active_step: i32,
    pub active_step_id: QString,
    pub running: bool,
    pub paused: bool,
    pub last_error: QString,
    /// Run-attempt state held between `run()` (which surfaces the
    /// trust prompt) and `confirm_trust()` / `cancel_trust()` (which
    /// resolve it). `None` outside that window.
    pending_trust: Option<PendingTrust>,
    /// Whether the pending run should start in debug mode. Set in
    /// `run_debug` before the trust prompt; consumed in
    /// `confirm_trust` (or directly when the workflow is already
    /// trusted).
    pending_debug: bool,
    /// Active debug session's command channel. Sender lives here so
    /// step_next / continue_run / stop_run can talk to the engine.
    /// `None` outside a debug run.
    debug_tx: Option<tokio::sync::mpsc::Sender<engine::DebugCommand>>,
}

/// What we need to resume a run after the user confirms trust.
struct PendingTrust {
    path: PathBuf,
    hash: String,
    workflow: Workflow,
}

impl Default for WorkflowControllerRust {
    fn default() -> Self {
        Self {
            workflow_json: QString::from(""),
            active_step: -1,
            active_step_id: QString::from(""),
            running: false,
            paused: false,
            last_error: QString::from(""),
            pending_trust: None,
            pending_debug: false,
            debug_tx: None,
        }
    }
}

impl qobject::WorkflowController {
    fn load(mut self: Pin<&mut Self>, id: QString) {
        let id_s: String = id.to_string();
        // GUI-side load: preserve the authored form so the editor can
        // show `use NAME` cards + the imports map as written. The
        // engine path expands in `run` before dispatch.
        match store::load_authored(&id_s) {
            Ok(wf) => {
                let json = serde_json::to_string(&wf).unwrap_or_else(|_| "{}".into());
                self.as_mut().set_workflow_json(QString::from(&json));
                self.as_mut().set_active_step(-1);
                self.as_mut().set_last_error(QString::from(""));
            }
            Err(e) => {
                tracing::warn!(?e, "load {}", id_s);
                self.as_mut().set_last_error(QString::from(&format!("{e:#}")));
            }
        }
    }

    fn load_fragment(mut self: Pin<&mut Self>, path: QString) {
        let path_s: String = path.to_string();
        let p = std::path::Path::new(&path_s);
        match kdl_format::decode_fragment_file(p) {
            Ok(steps) => {
                let title = p
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("fragment")
                    .to_string();
                let mut wf = Workflow::new(title);
                wf.id = format!("fragment:{}", p.to_string_lossy());
                wf.steps = steps;
                let json = serde_json::to_string(&wf).unwrap_or_else(|_| "{}".into());
                self.as_mut().set_workflow_json(QString::from(&json));
                self.as_mut().set_active_step(-1);
                self.as_mut().set_last_error(QString::from(""));
            }
            Err(e) => {
                tracing::warn!(?e, "load_fragment {}", path_s);
                self.as_mut()
                    .set_last_error(QString::from(&format!("{e:#}")));
            }
        }
    }

    fn save_fragment(
        mut self: Pin<&mut Self>,
        path: QString,
        json: QString,
    ) -> QString {
        let path_s: String = path.to_string();
        if path_s.is_empty() {
            self.as_mut()
                .set_last_error(QString::from("save_fragment: empty path"));
            return QString::from("");
        }
        let text: String = json.to_string();
        let wf: Workflow = match serde_json::from_str(&text) {
            Ok(wf) => wf,
            Err(e) => {
                tracing::warn!(?e, "save_fragment: bad json");
                self.as_mut()
                    .set_last_error(QString::from(&format!("bad json: {e}")));
                return QString::from("");
            }
        };
        // Encode just the steps; the fragment file is a bare list of
        // step nodes — no workflow wrapper, schema, or imports map.
        let body = kdl_format::encode_fragment(&wf.steps);
        let p = std::path::Path::new(&path_s);
        // Atomic write: tmp file + rename so a crash mid-write
        // doesn't truncate the fragment.
        let tmp = p.with_extension("kdl.tmp");
        if let Some(parent) = p.parent() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                tracing::warn!(?e, "save_fragment: mkdir parent");
                self.as_mut()
                    .set_last_error(QString::from(&format!("mkdir parent: {e}")));
                return QString::from("");
            }
        }
        if let Err(e) = std::fs::write(&tmp, body.as_bytes()) {
            tracing::warn!(?e, "save_fragment: write tmp");
            self.as_mut()
                .set_last_error(QString::from(&format!("write {}: {e}", tmp.display())));
            return QString::from("");
        }
        if let Err(e) = std::fs::rename(&tmp, p) {
            tracing::warn!(?e, "save_fragment: rename");
            self.as_mut()
                .set_last_error(QString::from(&format!(
                    "rename {} -> {}: {e}",
                    tmp.display(),
                    p.display()
                )));
            return QString::from("");
        }
        // Re-emit the synthesized workflow_json (unchanged shape) so
        // the editor's bindings stay live. Stable ids that the GUI
        // ensured are already in `wf` and survive the round-trip.
        let rewrap = serde_json::to_string(&wf).unwrap_or_else(|_| "{}".into());
        self.as_mut().set_workflow_json(QString::from(&rewrap));
        self.as_mut().set_last_error(QString::from(""));
        QString::from(&path_s)
    }

    fn resolve_import_path(
        mut self: Pin<&mut Self>,
        name: QString,
    ) -> QString {
        let name_s: String = name.to_string();
        let json: String = self.workflow_json.to_string();
        let wf: Workflow = match serde_json::from_str(&json) {
            Ok(wf) => wf,
            Err(_) => return QString::from(""),
        };
        // For a fragment-mode page (id starts with "fragment:"), the
        // base dir is the fragment file's parent. For a real workflow
        // it's the workflow file's parent.
        let base_dir = if let Some(stripped) = wf.id.strip_prefix("fragment:") {
            std::path::Path::new(stripped)
                .parent()
                .map(|p| p.to_path_buf())
                .unwrap_or_default()
        } else {
            match store::path_of(&wf.id) {
                Ok(p) => p.parent().map(|p| p.to_path_buf()).unwrap_or_default(),
                Err(e) => {
                    tracing::warn!(?e, "resolve_import_path: workflow has no on-disk path");
                    return QString::from("");
                }
            }
        };
        let path_str = match wf.imports.get(&name_s) {
            Some(p) => p.clone(),
            None => return QString::from(""),
        };
        match kdl_format::resolve_import_path(&path_str, &base_dir) {
            Ok(p) => QString::from(&p.to_string_lossy().to_string()),
            Err(e) => {
                tracing::warn!(?e, "resolve_import_path failed");
                self.as_mut()
                    .set_last_error(QString::from(&format!("{e:#}")));
                QString::from("")
            }
        }
    }

    fn save(mut self: Pin<&mut Self>, json: QString) -> QString {
        let text: String = json.to_string();
        let wf: Workflow = match serde_json::from_str(&text) {
            Ok(wf) => wf,
            Err(e) => {
                tracing::warn!(?e, "save: bad json");
                self.as_mut().set_last_error(QString::from(&format!("bad json: {e}")));
                return QString::from("");
            }
        };
        match store::save(wf) {
            Ok(saved) => {
                let rewrap = serde_json::to_string(&saved).unwrap_or_else(|_| "{}".into());
                self.as_mut().set_workflow_json(QString::from(&rewrap));
                QString::from(&saved.id)
            }
            Err(e) => {
                tracing::warn!(?e, "save failed");
                self.as_mut().set_last_error(QString::from(&format!("{e:#}")));
                QString::from("")
            }
        }
    }

    fn run(mut self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;

        if self.running {
            return;
        }
        let text: String = self.workflow_json.to_string();
        let mut wf: Workflow = match serde_json::from_str(&text) {
            Ok(wf) => wf,
            Err(e) => {
                tracing::warn!(?e, "run: bad workflow_json");
                self.as_mut().set_last_error(QString::from(&format!("bad json: {e}")));
                return;
            }
        };

        // Resolve the on-disk path so the trust check can hash it. If
        // the workflow has never been saved (id with no backing file),
        // path_of returns an error — treat that as "no file to verify"
        // and proceed (matches the in-memory-edit-then-run case the
        // GUI already supports). Anything else hard-errors.
        let path = match store::path_of(&wf.id) {
            Ok(p) => Some(p),
            Err(_) => None,
        };

        // Expand `use NAME` references against the workflow's
        // directory before handing the workflow to the engine. The
        // editor preserves the authored form; the engine wants the
        // inlined form. If the workflow has no on-disk path, expansion
        // can still succeed for absolute import paths; relative paths
        // would error (no base dir). The bridge surfaces that as
        // last_error rather than crashing the run.
        if let Some(p) = path.as_ref() {
            if let Err(e) = kdl_format::expand_imports_in_place(&mut wf, p) {
                tracing::warn!(?e, "expand_imports failed");
                self.as_mut().set_last_error(QString::from(&format!("{e:#}")));
                return;
            }
        } else if !wf.imports.is_empty() {
            // Best effort for unsaved workflows: try to expand against
            // an empty base dir. Absolute paths work; relative ones
            // surface a path-resolution error to the user.
            if let Err(e) = kdl_format::expand_imports_in_place(
                &mut wf,
                std::path::Path::new(""),
            ) {
                tracing::warn!(?e, "expand_imports failed (unsaved)");
                self.as_mut().set_last_error(QString::from(&format!("{e:#}")));
                return;
            }
        }

        let debug = self.as_ref().rust().pending_debug;
        match path {
            Some(p) => match security::check_trust(&p, security::TrustMode::Gui) {
                Ok(security::TrustDecision::Trusted) => {
                    self.as_mut().rust_mut().pending_debug = false;
                    if debug {
                        self.as_mut()._start_engine_debug(wf);
                    } else {
                        self.as_mut()._start_engine(wf);
                    }
                }
                Ok(security::TrustDecision::Untrusted { canonical_path, hash }) => {
                    // pending_debug stays set; confirm_trust reads it.
                    let summary = build_trust_summary(&wf);
                    self.as_mut().rust_mut().pending_trust = Some(PendingTrust {
                        path: canonical_path,
                        hash,
                        workflow: wf,
                    });
                    self.as_mut().trust_prompt_required(QString::from(&summary));
                }
                Err(e) => {
                    tracing::warn!(?e, "trust check failed");
                    self.as_mut().rust_mut().pending_debug = false;
                    self.as_mut().set_last_error(QString::from(&format!("{e:#}")));
                }
            },
            None => {
                // Unsaved workflow — skip trust check, run directly.
                self.as_mut().rust_mut().pending_debug = false;
                if debug {
                    self.as_mut()._start_engine_debug(wf);
                } else {
                    self.as_mut()._start_engine(wf);
                }
            }
        }
    }

    fn confirm_trust(mut self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;

        let pending = self.as_mut().rust_mut().pending_trust.take();
        let pt = match pending {
            Some(pt) => pt,
            None => return, // nothing to confirm
        };
        if let Err(e) = security::mark_trusted(&pt.path, &pt.hash) {
            tracing::warn!(?e, "mark_trusted after confirm");
            // Don't block the run — we still got the user's explicit
            // ok. Worst case the next run re-prompts.
        }
        // Honour run_debug's pending_debug flag if it's set, then
        // clear it so a follow-up plain run() doesn't accidentally
        // start in debug mode.
        let debug = self.as_ref().rust().pending_debug;
        self.as_mut().rust_mut().pending_debug = false;
        if debug {
            self.as_mut()._start_engine_debug(pt.workflow);
        } else {
            self.as_mut()._start_engine(pt.workflow);
        }
    }

    fn run_debug(mut self: Pin<&mut Self>) {
        // Reuse the same trust + workflow-prep flow as run(). The
        // pending_debug flag is consumed in confirm_trust /
        // _route_run, so the engine spawn picks the right entry
        // point.
        use cxx_qt::CxxQtType;
        self.as_mut().rust_mut().pending_debug = true;
        self.as_mut().run();
    }

    fn step_next(self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        if let Some(tx) = self.as_ref().rust().debug_tx.clone() {
            // Best-effort. try_send so we don't block the Qt thread
            // if the channel is full (it's never full at depth 4 in
            // practice, but defensively).
            let _ = tx.try_send(engine::DebugCommand::Step);
        }
    }

    fn continue_run(self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        if let Some(tx) = self.as_ref().rust().debug_tx.clone() {
            let _ = tx.try_send(engine::DebugCommand::Continue);
        }
    }

    fn stop_run(self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        if let Some(tx) = self.as_ref().rust().debug_tx.clone() {
            let _ = tx.try_send(engine::DebugCommand::Stop);
        }
    }

    fn cancel_trust(mut self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        self.as_mut().rust_mut().pending_trust = None;
        // No engine started, no run_finished to emit. The trust
        // dialog closes itself.
    }

    /// Spin up the engine on a tokio task with a Qt-thread sink that
    /// posts each event back. Shared by `run()` (when the workflow is
    /// already trusted or unsaved) and `confirm_trust()` (after the
    /// user confirms via the trust dialog).
    fn _start_engine(mut self: Pin<&mut Self>, wf: Workflow) {
        self.as_mut().set_running(true);
        self.as_mut().set_paused(false);
        self.as_mut().set_active_step(-1);
        self.as_mut().set_last_error(QString::from(""));

        let sink = self.as_mut()._build_sink();

        let wf_id = wf.id.clone();
        tokio::spawn(async move {
            if let Err(e) = engine::run_workflow(sink, wf).await {
                tracing::warn!(?e, "run_workflow failed");
            }
            // `touch_last_run` on a best-effort basis — the Finished event
            // has already fired from inside run_workflow.
            store::touch_last_run(&wf_id);
        });
    }

    /// Debug variant of _start_engine. Same setup but creates a
    /// command channel, stashes the sender for step_next /
    /// continue_run / stop_run to use, and runs the workflow under
    /// PauseControl::on so the engine pauses before each step.
    fn _start_engine_debug(mut self: Pin<&mut Self>, wf: Workflow) {
        use cxx_qt::CxxQtType;
        self.as_mut().set_running(true);
        self.as_mut().set_paused(false);
        self.as_mut().set_active_step(-1);
        self.as_mut().set_last_error(QString::from(""));

        // Bounded channel — a few buffered commands is plenty; the
        // engine consumes each one before requesting the next, so
        // depth 4 is generous.
        let (tx, rx) = tokio::sync::mpsc::channel::<engine::DebugCommand>(4);
        self.as_mut().rust_mut().debug_tx = Some(tx);

        let sink = self.as_mut()._build_sink();

        let wf_id = wf.id.clone();
        let pause = engine::PauseControl::on(rx);
        tokio::spawn(async move {
            if let Err(e) = engine::run_workflow_with(sink, wf, pause).await {
                tracing::warn!(?e, "run_workflow_with failed");
            }
            store::touch_last_run(&wf_id);
        });
    }

    /// Build the shared event-sink closure used by both run modes.
    /// Each event posts back to the Qt thread and updates the
    /// matching qproperty / signal. Pulled out so the two engine
    /// entry points stay short and identical apart from the
    /// PauseControl + debug_tx handling.
    fn _build_sink(mut self: Pin<&mut Self>) -> engine::EventSink {
        let qt_thread = self.qt_thread();
        Arc::new(move |ev: RunEvent| {
            let thread = qt_thread.clone();
            let _ = thread.queue(move |mut ctrl: Pin<&mut qobject::WorkflowController>| {
                use cxx_qt::CxxQtType;
                match ev {
                    RunEvent::Started { .. } => {}
                    RunEvent::StepStart { index, step_id } => {
                        ctrl.as_mut().set_paused(false);
                        ctrl.as_mut().set_active_step(index as i32);
                        ctrl.as_mut().set_active_step_id(QString::from(&step_id));
                        ctrl.as_mut().step_started(
                            index as i32,
                            QString::from(&step_id),
                        );
                    }
                    RunEvent::StepDone {
                        index, step_id, outcome, ..
                    } => {
                        let (status, message) = match &outcome {
                            StepOutcome::Ok { output, .. } => (
                                "ok",
                                output.clone().unwrap_or_default(),
                            ),
                            StepOutcome::Skipped { reason } => ("skipped", reason.clone()),
                            StepOutcome::Error { message, .. } => ("error", message.clone()),
                        };
                        ctrl.as_mut().step_done(
                            index as i32,
                            QString::from(&step_id),
                            QString::from(status),
                            QString::from(&message),
                        );
                        if matches!(outcome, StepOutcome::Error { .. }) {
                            ctrl.as_mut().set_last_error(QString::from(&message));
                        }
                    }
                    RunEvent::Paused { index } => {
                        ctrl.as_mut().set_paused(true);
                        ctrl.as_mut().set_active_step(index as i32);
                    }
                    RunEvent::Finished { ok, .. } => {
                        ctrl.as_mut().set_running(false);
                        ctrl.as_mut().set_paused(false);
                        ctrl.as_mut().set_active_step(-1);
                        ctrl.as_mut().set_active_step_id(QString::from(""));
                        ctrl.as_mut().rust_mut().debug_tx = None;
                        ctrl.as_mut().run_finished(ok);
                    }
                }
            });
        })
    }
}

/// Multi-line human-readable summary of what the workflow will do.
/// Mirrors the format `cli::cmd_run` prints on its own trust prompt
/// so users see consistent copy across CLI and GUI.
fn build_trust_summary(wf: &Workflow) -> String {
    let mut out = String::new();
    out.push_str("This workflow will:\n");
    let mut shown = 0usize;
    for step in &wf.steps {
        if !step.enabled {
            continue;
        }
        let kind = step.action.category();
        let marker = match kind {
            "shell" | "clipboard" => "•",
            _ => "·",
        };
        out.push_str(&format!(
            "  {marker} {kind:<9} {desc}\n",
            desc = step.action.describe()
        ));
        shown += 1;
        if shown >= 12 && wf.steps.len() > 12 {
            out.push_str(&format!(
                "  · ... and {} more\n",
                wf.steps.len() - shown
            ));
            break;
        }
    }
    out
}
