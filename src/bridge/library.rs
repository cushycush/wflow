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

        /// Duplicate a workflow. Loads it, mints a fresh id, appends a
        /// " (copy)" suffix to the title, saves, and returns the new id.
        #[qinvokable]
        fn duplicate(self: Pin<&mut LibraryController>, id: QString) -> QString;

        /// Persist the canvas card positions for a workflow. `json` is
        /// a stringified map of step-id → {x, y}. Stored alongside
        /// other workflow metadata in `workflows.toml`.
        #[qinvokable]
        fn save_positions(
            self: Pin<&mut LibraryController>,
            id: QString,
            json: QString,
        );

        /// Load the saved canvas card positions for a workflow.
        /// Returns a stringified map of step-id → {x, y}; empty
        /// JSON object if no positions have been saved.
        #[qinvokable]
        fn load_positions(self: Pin<&mut LibraryController>, id: QString) -> QString;

        /// Move a workflow into the named folder. An empty string
        /// clears the folder (back to top-level). Refreshes the
        /// `workflows` summary so the library re-renders.
        #[qinvokable]
        fn set_folder(
            self: Pin<&mut LibraryController>,
            id: QString,
            folder: QString,
        );

        /// All folder names that exist as subdirectories under the
        /// workflows root. Returned as a JSON array of strings,
        /// sorted ascending. Empty folders are included so a freshly-
        /// created folder shows up before any workflow is in it.
        #[qinvokable]
        fn folders(self: Pin<&mut LibraryController>) -> QString;

        /// Create a folder by mkdir-ing it under the workflows root.
        /// No-op if it already exists. Refreshes the workflows
        /// summary so the library picks up the new folder.
        #[qinvokable]
        fn create_folder(self: Pin<&mut LibraryController>, name: QString);
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
    /// Folder / category from `workflows.toml`. Empty string when
    /// the workflow lives at the top level (no folder assigned).
    folder: String,
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

    fn duplicate(mut self: Pin<&mut Self>, id: QString) -> QString {
        let id_s: String = id.to_string();
        let mut wf = match store::load(&id_s) {
            Ok(wf) => wf,
            Err(e) => {
                tracing::warn!(?e, "duplicate: load {} failed", id_s);
                return QString::from("");
            }
        };
        // Fresh identity so the copy lives alongside the original.
        wf.id = uuid::Uuid::new_v4().to_string();
        wf.title = format!("{} (copy)", wf.title);
        let now = chrono::Utc::now();
        wf.created = Some(now);
        wf.modified = Some(now);
        wf.last_run = None;
        // Mint new step ids so an editor's step-by-id references on the
        // copy don't accidentally touch the original.
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

    fn save_positions(self: Pin<&mut Self>, id: QString, json: QString) {
        let id_s: String = id.to_string();
        if id_s.is_empty() {
            return;
        }
        let json_s: String = json.to_string();
        // QML sends an object literal { "stepId": {x, y}, ... }. Parse
        // into a step-id → [x, y] map so it sits cleanly in the toml.
        #[derive(serde::Deserialize)]
        struct Pt {
            x: f64,
            y: f64,
        }
        let parsed: std::collections::HashMap<String, Pt> =
            match serde_json::from_str(&json_s) {
                Ok(v) => v,
                Err(e) => {
                    tracing::warn!(?e, "save_positions: bad JSON");
                    return;
                }
            };
        let mut as_btree: std::collections::BTreeMap<String, [f64; 2]> =
            std::collections::BTreeMap::new();
        for (k, p) in parsed {
            as_btree.insert(k, [p.x, p.y]);
        }
        crate::workflows_meta::set_positions(&id_s, as_btree);
    }

    fn load_positions(self: Pin<&mut Self>, id: QString) -> QString {
        let id_s: String = id.to_string();
        if id_s.is_empty() {
            return QString::from("{}");
        }
        let positions = crate::workflows_meta::get_positions(&id_s);
        // Re-shape into { id: { x, y } } so QML's positions map can
        // assign the result directly.
        let mut out = serde_json::Map::new();
        for (k, [x, y]) in positions {
            let mut inner = serde_json::Map::new();
            inner.insert("x".into(), serde_json::Value::from(x));
            inner.insert("y".into(), serde_json::Value::from(y));
            out.insert(k, serde_json::Value::Object(inner));
        }
        let s = serde_json::to_string(&serde_json::Value::Object(out))
            .unwrap_or_else(|_| "{}".to_string());
        QString::from(&s)
    }

    fn set_folder(mut self: Pin<&mut Self>, id: QString, folder: QString) {
        let id_s: String = id.to_string();
        if id_s.is_empty() {
            return;
        }
        let folder_s: String = folder.to_string();
        let folder_opt = if folder_s.is_empty() { None } else { Some(folder_s.as_str()) };
        // Move the file on disk so library = filesystem layout.
        if let Err(e) = store::move_to_folder(&id_s, folder_opt) {
            tracing::warn!(?e, "set_folder: move failed");
            return;
        }
        // Re-render the library — workflow's folder column changes.
        self.as_mut().set_workflows(load_as_json());
    }

    fn folders(self: Pin<&mut Self>) -> QString {
        let folders = store::list_folders().unwrap_or_default();
        let s = serde_json::to_string(&folders).unwrap_or_else(|_| "[]".to_string());
        QString::from(&s)
    }

    fn create_folder(mut self: Pin<&mut Self>, name: QString) {
        let n: String = name.to_string();
        if n.is_empty() {
            return;
        }
        if let Err(e) = store::create_folder(&n) {
            tracing::warn!(?e, "create_folder failed");
            return;
        }
        // Refresh — folder count badge in the sidebar updates.
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
                let folder = wf.folder.clone().unwrap_or_default();
                WorkflowSummary {
                    id: wf.id,
                    title: wf.title,
                    subtitle: wf.subtitle.unwrap_or_default(),
                    steps: wf.steps.len(),
                    last_run: wf.last_run.map(|t| t.to_rfc3339()),
                    modified: wf.modified.map(|t| t.to_rfc3339()),
                    kinds,
                    folder,
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
