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

        /// `json` is `{ stepId: {x, y}, ... }`. Stored in workflows.toml.
        #[qinvokable]
        fn save_positions(
            self: Pin<&mut LibraryController>,
            id: QString,
            json: QString,
        );

        /// Empty `{}` when no positions are saved.
        #[qinvokable]
        fn load_positions(self: Pin<&mut LibraryController>, id: QString) -> QString;

        /// Empty folder = move back to top-level.
        #[qinvokable]
        fn set_folder(
            self: Pin<&mut LibraryController>,
            id: QString,
            folder: QString,
        );

        /// JSON array, sorted ascending. Includes empty folders.
        #[qinvokable]
        fn folders(self: Pin<&mut LibraryController>) -> QString;

        #[qinvokable]
        fn create_folder(self: Pin<&mut LibraryController>, name: QString);
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
    trail: Vec<TrailEntry>,
    folder: String,
}

#[derive(Serialize)]
struct TrailEntry {
    kind: &'static str,
    value: String,
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

    fn save_positions(self: Pin<&mut Self>, id: QString, json: QString) {
        let id_s: String = id.to_string();
        if id_s.is_empty() {
            return;
        }
        let json_s: String = json.to_string();
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
        if let Err(e) = store::move_to_folder(&id_s, folder_opt) {
            tracing::warn!(?e, "set_folder: move failed");
            return;
        }
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
                let trail: Vec<TrailEntry> = wf
                    .steps
                    .iter()
                    .take(12)
                    .map(|s| TrailEntry {
                        kind: s.action.category(),
                        value: crate::actions::step_value_label(&s.action),
                    })
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
                    trail,
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
