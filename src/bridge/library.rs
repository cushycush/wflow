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

        /// Bind a keyboard chord to a workflow. Replaces any existing
        /// chord trigger on the workflow (one-chord-per-workflow is
        /// the v1 model — additional chord shapes can land later).
        /// Empty string clears the trigger entirely. Validates the
        /// chord through `actions::normalize_chord` before saving so
        /// "Cmd+Shift+T" canonicalises to "super+shift+t" on disk
        /// and the daemon's chord-string compare works deterministically.
        /// Refreshes the workflows summary so the Triggers list /
        /// editor re-renders. The trigger daemon's file watcher
        /// picks up the change automatically.
        ///
        /// Returns the canonical chord string on success, empty
        /// string on any failure (workflow not found, save failed).
        #[qinvokable]
        fn set_chord(
            self: Pin<&mut LibraryController>,
            id: QString,
            chord: QString,
        ) -> QString;
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
    /// Per-step `{kind, value}` for the chip trail on the library
    /// card — same shape as the Explore catalog row's `actionTypes`.
    /// Capped to 12 entries so the JSON payload stays small for
    /// large libraries; the card only renders the first six anyway,
    /// the cap leaves headroom for the +N sentinel without
    /// over-serialising.
    trail: Vec<TrailEntry>,
    /// Folder / category from `workflows.toml`. Empty string when
    /// the workflow lives at the top level (no folder assigned).
    folder: String,
    /// Bound keyboard chord (e.g. "ctrl+shift+t"), or empty string
    /// when no chord trigger is configured. v1 surfaces only the
    /// first chord trigger — multi-chord workflows are rare, the
    /// model accepts them but the GUI binds one-at-a-time.
    chord: String,
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

    fn set_chord(
        mut self: Pin<&mut Self>,
        id: QString,
        chord: QString,
    ) -> QString {
        let id_s: String = id.to_string();
        let chord_s: String = chord.to_string();

        // Empty chord = clear all chord triggers on this workflow.
        // Per-window predicates and hotstrings (v0.5+) survive — we
        // only touch chord-shaped triggers so the v0.4 "Chord"
        // variant is the one we manage.
        let mut wf = match crate::store::load(&id_s) {
            Ok(w) => w,
            Err(e) => {
                tracing::warn!(?e, "set_chord: load {id_s} failed");
                return QString::from("");
            }
        };

        // Drop any existing chord triggers so the new one (if any)
        // doesn't end up as a duplicate. v1 binds one chord per
        // workflow — the daemon would warn on duplicates anyway.
        wf.triggers.retain(|t| !matches!(
            t.kind,
            crate::actions::TriggerKind::Chord { .. }
        ));

        let canonical = if chord_s.trim().is_empty() {
            String::new()
        } else {
            let normalized = crate::actions::normalize_chord(chord_s.trim());
            wf.triggers.push(crate::actions::Trigger {
                kind: crate::actions::TriggerKind::Chord {
                    chord: normalized.clone(),
                },
                when: None,
            });
            normalized
        };

        if let Err(e) = crate::store::save(wf) {
            tracing::warn!(?e, "set_chord: save {id_s} failed");
            return QString::from("");
        }

        // Refresh the workflows summary so any QML view (Library
        // grid, Triggers tab, the editor's trigger panel) re-renders
        // the new chord state. The trigger daemon's file watcher
        // sees the KDL change and re-binds without a restart.
        self.as_mut().set_workflows(load_as_json());
        QString::from(&canonical)
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
                // Surface the first chord trigger to QML. Multi-
                // chord workflows are rare and v1's GUI binds one-
                // at-a-time; the daemon still parses and respects
                // every trigger block in the KDL regardless.
                let chord = wf
                    .triggers
                    .iter()
                    .find_map(|t| match &t.kind {
                        crate::actions::TriggerKind::Chord { chord } => Some(chord.clone()),
                        _ => None,
                    })
                    .unwrap_or_default();
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
                    chord,
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
