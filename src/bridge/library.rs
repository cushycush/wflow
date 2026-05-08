//! LibraryController, the workflow library surface for QML. Lists ship
//! as a JSON QString; replace with QAbstractListModel if anyone hits
//! library sizes that make `JSON.parse` slow.

use std::pin::Pin;

use cxx_qt::Threading;
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

        /// Bind a chord to a workflow. Empty `chord` clears the binding.
        /// `when_kind` is "window-class" / "window-title", or empty for
        /// unconditional. Returns the canonical chord, empty on failure.
        #[qinvokable]
        fn set_chord(
            self: Pin<&mut LibraryController>,
            id: QString,
            chord: QString,
            when_kind: QString,
            when_value: QString,
        ) -> QString;

        /// Spawn a notify watcher on the workflows dir so chord edits
        /// from another page (or external KDL edits) refresh this
        /// controller's `workflows`. Idempotent; QML calls from
        /// `Component.onCompleted`. Without this, sibling pages keep
        /// stale snapshots and the daemon's hot-reload story is a
        /// daemon-only feature.
        #[qinvokable]
        fn start_watching(self: Pin<&mut LibraryController>);
    }

    impl cxx_qt::Threading for LibraryController {}
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
    /// First chord trigger only. Multi-chord workflows are rare;
    /// the daemon honors all of them, the GUI binds one.
    chord: String,
    chord_when_kind: String,
    chord_when_value: String,
}

#[derive(Serialize)]
struct TrailEntry {
    kind: &'static str,
    value: String,
}

pub struct LibraryControllerRust {
    pub workflows: QString,
    /// Held to keep the inotify FD open. Notify cancels its watch when
    /// the watcher drops, so anything less than ownership-by-the-controller
    /// would silently stop firing the moment start_watching returned.
    watcher: Option<notify::RecommendedWatcher>,
}

impl Default for LibraryControllerRust {
    fn default() -> Self {
        Self {
            workflows: load_as_json(),
            watcher: None,
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

    fn set_chord(
        mut self: Pin<&mut Self>,
        id: QString,
        chord: QString,
        when_kind: QString,
        when_value: QString,
    ) -> QString {
        let id_s: String = id.to_string();
        let chord_s: String = chord.to_string();
        let when_kind_s: String = when_kind.to_string();
        let when_value_s: String = when_value.to_string();

        // We only touch Chord triggers; hotstrings and other shapes survive.
        let mut wf = match crate::store::load(&id_s) {
            Ok(w) => w,
            Err(e) => {
                tracing::warn!(?e, "set_chord: load {id_s} failed");
                return QString::from("");
            }
        };

        wf.triggers.retain(|t| !matches!(
            t.kind,
            crate::actions::TriggerKind::Chord { .. }
        ));

        let canonical = if chord_s.trim().is_empty() {
            String::new()
        } else {
            let normalized = crate::actions::normalize_chord(chord_s.trim());
            let when = build_trigger_condition(&when_kind_s, &when_value_s);
            wf.triggers.push(crate::actions::Trigger {
                kind: crate::actions::TriggerKind::Chord {
                    chord: normalized.clone(),
                },
                when,
            });
            normalized
        };

        if let Err(e) = crate::store::save(wf) {
            tracing::warn!(?e, "set_chord: save {id_s} failed");
            return QString::from("");
        }

        self.as_mut().set_workflows(load_as_json());
        QString::from(&canonical)
    }

    fn start_watching(mut self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        use notify::Watcher;

        if self.as_ref().rust().watcher.is_some() {
            return;
        }

        let dir = match crate::store::workflows_dir() {
            Ok(d) => d,
            Err(e) => {
                tracing::warn!(?e, "library hot-reload disabled: no workflows dir");
                return;
            }
        };

        // Editor saves emit 2-4 fsops in a burst (tmp write, rename,
        // mtime touch); the daemon settles them with a 250ms tick and
        // we mirror that here.
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        let mut watcher = match notify::recommended_watcher(
            move |res: notify::Result<notify::Event>| {
                if res.is_ok() {
                    let _ = tx.send(());
                }
            },
        ) {
            Ok(w) => w,
            Err(e) => {
                tracing::warn!(?e, "library hot-reload: couldn't create watcher");
                return;
            }
        };

        // Recursive so chords inside subfolders are still picked up.
        if let Err(e) = watcher.watch(&dir, notify::RecursiveMode::Recursive) {
            tracing::warn!(?e, "library hot-reload: couldn't watch {}", dir.display());
            return;
        }

        let qt_thread = self.qt_thread();
        std::thread::Builder::new()
            .name("wflow-library-watch".into())
            .spawn(move || {
                while rx.recv().is_ok() {
                    std::thread::sleep(std::time::Duration::from_millis(150));
                    while rx.try_recv().is_ok() {}
                    let _ = qt_thread.queue(
                        |mut ctrl: Pin<&mut qobject::LibraryController>| {
                            ctrl.as_mut().refresh();
                        },
                    );
                }
                tracing::debug!("library watch thread: channel closed, exiting");
            })
            .expect("spawn library watch thread");

        self.as_mut().rust_mut().watcher = Some(watcher);
        tracing::debug!(path = %dir.display(), "library hot-reload armed");
    }
}

/// Empty kind or value → None. Unknown kind logs a warn and falls
/// back to None so the chord still binds.
fn build_trigger_condition(
    kind: &str,
    value: &str,
) -> Option<crate::actions::TriggerCondition> {
    let kind = kind.trim();
    let value = value.trim();
    if kind.is_empty() || value.is_empty() {
        return None;
    }
    match kind {
        "window-class" | "window_class" => {
            Some(crate::actions::TriggerCondition::WindowClass {
                class: value.to_string(),
            })
        }
        "window-title" | "window_title" => {
            Some(crate::actions::TriggerCondition::WindowTitle {
                title: value.to_string(),
            })
        }
        other => {
            tracing::warn!(
                "set_chord: unknown when-kind {other}; binding without a predicate"
            );
            None
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
                let (chord, chord_when_kind, chord_when_value) = wf
                    .triggers
                    .iter()
                    .find_map(|t| match &t.kind {
                        crate::actions::TriggerKind::Chord { chord } => {
                            let (kind, value) = match &t.when {
                                Some(crate::actions::TriggerCondition::WindowClass { class }) => (
                                    "window-class".to_string(),
                                    class.clone(),
                                ),
                                Some(crate::actions::TriggerCondition::WindowTitle { title }) => (
                                    "window-title".to_string(),
                                    title.clone(),
                                ),
                                None => (String::new(), String::new()),
                            };
                            Some((chord.clone(), kind, value))
                        }
                        _ => None,
                    })
                    .unwrap_or_else(|| (String::new(), String::new(), String::new()));
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
                    chord_when_kind,
                    chord_when_value,
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
