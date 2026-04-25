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
use crate::{engine, security, store};

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
        #[qproperty(bool, running)]
        #[qproperty(QString, last_error)]
        type WorkflowController = super::WorkflowControllerRust;

        /// Load a workflow from disk into `workflow_json`.
        #[qinvokable]
        fn load(self: Pin<&mut WorkflowController>, id: QString);

        /// Save a workflow passed in as JSON text.
        /// Returns the id the workflow was saved under (== input's id).
        #[qinvokable]
        fn save(self: Pin<&mut WorkflowController>, json: QString) -> QString;

        /// Run the current workflow. Returns immediately. If the
        /// workflow file is trusted (see src/security.rs), progress is
        /// surfaced via step_done / run_finished signals and the
        /// active_step / running properties. If the file is untrusted,
        /// `trust_prompt_required` fires instead and the engine waits
        /// for a `confirm_trust` or `cancel_trust` call before
        /// proceeding.
        #[qinvokable]
        fn run(self: Pin<&mut WorkflowController>);

        /// Confirm a pending untrusted-workflow run. Marks the file
        /// trusted on disk and starts the engine.
        #[qinvokable]
        fn confirm_trust(self: Pin<&mut WorkflowController>);

        /// Cancel a pending untrusted-workflow run. Clears the pending
        /// state without marking trusted; the engine never starts.
        #[qinvokable]
        fn cancel_trust(self: Pin<&mut WorkflowController>);

        /// Signalled after each step completes.
        /// `status` is one of "ok" | "skipped" | "error".
        #[qsignal]
        fn step_done(
            self: Pin<&mut WorkflowController>,
            index: i32,
            status: QString,
            message: QString,
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
    pub running: bool,
    pub last_error: QString,
    /// Run-attempt state held between `run()` (which surfaces the
    /// trust prompt) and `confirm_trust()` / `cancel_trust()` (which
    /// resolve it). `None` outside that window.
    pending_trust: Option<PendingTrust>,
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
            running: false,
            last_error: QString::from(""),
            pending_trust: None,
        }
    }
}

impl qobject::WorkflowController {
    fn load(mut self: Pin<&mut Self>, id: QString) {
        let id_s: String = id.to_string();
        match store::load(&id_s) {
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
        let wf: Workflow = match serde_json::from_str(&text) {
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

        match path {
            Some(p) => match security::check_trust(&p, security::TrustMode::Gui) {
                Ok(security::TrustDecision::Trusted) => {
                    self.as_mut()._start_engine(wf);
                }
                Ok(security::TrustDecision::Untrusted { canonical_path, hash }) => {
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
                    self.as_mut().set_last_error(QString::from(&format!("{e:#}")));
                }
            },
            None => {
                // Unsaved workflow — skip trust check, run directly.
                self.as_mut()._start_engine(wf);
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
        self.as_mut()._start_engine(pt.workflow);
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
        self.as_mut().set_active_step(-1);
        self.as_mut().set_last_error(QString::from(""));

        // Post updates back to the Qt thread from the async task.
        let qt_thread = self.qt_thread();

        let sink: engine::EventSink = Arc::new(move |ev: RunEvent| {
            let thread = qt_thread.clone();
            let _ = thread.queue(move |mut ctrl: Pin<&mut qobject::WorkflowController>| {
                match ev {
                    RunEvent::Started { .. } => {}
                    RunEvent::StepStart { index, .. } => {
                        ctrl.as_mut().set_active_step(index as i32);
                    }
                    RunEvent::StepDone {
                        index, outcome, ..
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
                            QString::from(status),
                            QString::from(&message),
                        );
                        if matches!(outcome, StepOutcome::Error { .. }) {
                            ctrl.as_mut().set_last_error(QString::from(&message));
                        }
                    }
                    RunEvent::Finished { ok, .. } => {
                        ctrl.as_mut().set_running(false);
                        ctrl.as_mut().set_active_step(-1);
                        ctrl.as_mut().run_finished(ok);
                    }
                }
            });
        });

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
