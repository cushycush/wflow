//! LibraryController — the workflow library surface exposed to QML.
//!
//! Design choice: we serialize the list to JSON and ship it across as a
//! single QString property. cxx-qt has reasonable QVariantMap support but
//! JSON is less ceremony and QML can `JSON.parse(...)` it cheaply at a
//! scale of tens-to-low-hundreds of workflows. Revisit with a proper
//! QAbstractListModel if a user ever ships 10,000 workflows.

use std::pin::Pin;

use cxx_qt_lib::QString;
use serde::Serialize;

use crate::store;

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
    }

    unsafe extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[qproperty(QString, workflows)]
        type LibraryController = super::LibraryControllerRust;

        /// Re-read the workflows directory and update `workflows`.
        #[qinvokable]
        fn refresh(self: Pin<&mut LibraryController>);

        /// Create a blank workflow, persist it, and return its id.
        #[qinvokable]
        fn new_workflow(self: Pin<&mut LibraryController>, title: QString) -> QString;

        /// Delete a workflow by id. Refreshes the list.
        #[qinvokable]
        fn remove(self: Pin<&mut LibraryController>, id: QString);
    }
}

/// Shape sent to QML — a compact summary, not the full step list. Step
/// detail is loaded lazily via `WorkflowController.load(id)`.
#[derive(Serialize)]
struct WorkflowSummary {
    id: String,
    title: String,
    subtitle: String,
    steps: usize,
    last_run: Option<String>,
    modified: Option<String>,
    kinds: Vec<String>,
}

pub struct LibraryControllerRust {
    pub workflows: QString,
}

impl Default for LibraryControllerRust {
    fn default() -> Self {
        // Populate on construction so QML sees the current library on the
        // first bind, not after a ping.
        Self {
            workflows: load_as_json(),
        }
    }
}

impl qobject::LibraryController {
    fn refresh(mut self: Pin<&mut Self>) {
        self.as_mut().set_workflows(load_as_json());
    }

    fn new_workflow(mut self: Pin<&mut Self>, title: QString) -> QString {
        let title_s: String = title.to_string();
        let title_s = if title_s.trim().is_empty() {
            "Untitled".into()
        } else {
            title_s
        };
        let wf = crate::actions::Workflow::new(title_s);
        let id = wf.id.clone();
        match store::save(wf) {
            Ok(_) => {
                self.as_mut().set_workflows(load_as_json());
                QString::from(&id)
            }
            Err(e) => {
                tracing::warn!(?e, "new_workflow save failed");
                QString::from("")
            }
        }
    }

    fn remove(mut self: Pin<&mut Self>, id: QString) {
        let id_s: String = id.to_string();
        if let Err(e) = store::delete(&id_s) {
            tracing::warn!(?e, "delete failed");
            return;
        }
        self.as_mut().set_workflows(load_as_json());
    }
}

fn load_as_json() -> QString {
    let summaries: Vec<WorkflowSummary> = match store::list() {
        Ok(list) => list
            .into_iter()
            .map(|wf| {
                let kinds: Vec<String> = wf
                    .steps
                    .iter()
                    .map(|s| s.action.category().to_string())
                    .collect();
                WorkflowSummary {
                    id: wf.id,
                    title: wf.title,
                    subtitle: wf.subtitle.unwrap_or_default(),
                    steps: wf.steps.len(),
                    last_run: wf.last_run.map(|t| t.to_rfc3339()),
                    modified: wf.modified.map(|t| t.to_rfc3339()),
                    kinds,
                }
            })
            .collect(),
        Err(e) => {
            tracing::warn!(?e, "store::list failed");
            Vec::new()
        }
    };
    QString::from(&serde_json::to_string(&summaries).unwrap_or_else(|_| "[]".into()))
}
