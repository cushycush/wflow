//! WorkflowController — the currently-open workflow.
//!
//! Loads a workflow by id, exposes its JSON to QML for read + edit,
//! persists back to disk, and runs the engine on a background tokio
//! task that posts per-step updates back onto the Qt thread.

use std::pin::Pin;
use std::sync::Arc;

use cxx_qt::Threading;
use cxx_qt_lib::QString;

use crate::actions::{RunEvent, StepOutcome, Workflow};
use crate::{engine, store};

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

        /// Run the current workflow. Returns immediately; progress is
        /// surfaced via step_done / run_finished signals and the
        /// active_step / running properties.
        #[qinvokable]
        fn run(self: Pin<&mut WorkflowController>);

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
    }

    impl cxx_qt::Threading for WorkflowController {}
}

pub struct WorkflowControllerRust {
    pub workflow_json: QString,
    pub active_step: i32,
    pub running: bool,
    pub last_error: QString,
}

impl Default for WorkflowControllerRust {
    fn default() -> Self {
        Self {
            workflow_json: QString::from(""),
            active_step: -1,
            running: false,
            last_error: QString::from(""),
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
