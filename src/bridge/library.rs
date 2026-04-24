//! LibraryController, the workflow library surface for QML. Lists ship
//! as a JSON QString; replace with QAbstractListModel if anyone hits
//! library sizes that make `JSON.parse` slow.

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

        #[qinvokable]
        fn refresh(self: Pin<&mut LibraryController>);

        #[qinvokable]
        fn new_workflow(self: Pin<&mut LibraryController>, title: QString) -> QString;

        #[qinvokable]
        fn remove(self: Pin<&mut LibraryController>, id: QString);

        /// Mints a fresh id, suffixes " (copy)" on the title.
        #[qinvokable]
        fn duplicate(self: Pin<&mut LibraryController>, id: QString) -> QString;
    }
}

/// Compact summary for QML; step detail loads lazily via
/// `WorkflowController.load(id)`. `trail` is capped at 12 since the
/// card renders six and a +N badge.
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

    fn duplicate(mut self: Pin<&mut Self>, id: QString) -> QString {
        let id_s: String = id.to_string();
        let mut wf = match store::load(&id_s) {
            Ok(wf) => wf,
            Err(e) => {
                tracing::warn!(?e, "duplicate: load {} failed", id_s);
                return QString::from("");
            }
        };
        wf.id = uuid::Uuid::new_v4().to_string();
        wf.title = format!("{} (copy)", wf.title);
        let now = chrono::Utc::now();
        wf.created = Some(now);
        wf.modified = Some(now);
        wf.last_run = None;
        // Fresh step ids so editor lookups don't cross-target the original.
        for step in &mut wf.steps {
            step.id = uuid::Uuid::new_v4().to_string();
        }
        match store::save(wf) {
            Ok(saved) => {
                self.as_mut().set_workflows(load_as_json());
                QString::from(&saved.id)
            }
            Err(e) => {
                tracing::warn!(?e, "duplicate save failed");
                QString::from("")
            }
        }
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
