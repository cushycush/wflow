//! StateController — UX onboarding state exposed to QML.
//!
//! Owns:
//!
//!   - `is_first_run`     — true until `mark_first_run_seen()` is called
//!   - `templates_json`   — JSON list of available workflow templates
//!     (from `crate::templates::discover()`)
//!   - tutorial-seen flags accessed via invokable methods
//!
//! Persistence is delegated to `crate::state` (the `state.toml` reader/
//! writer). All saves are best-effort — a write failure logs and
//! continues; the in-memory state remains the truth for the running
//! session.

use std::pin::Pin;

use cxx_qt_lib::QString;
use serde::Serialize;

use crate::{state, templates};

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
    }

    unsafe extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[qproperty(bool, is_first_run)]
        #[qproperty(QString, templates_json)]
        #[qproperty(QString, theme_mode)]
        #[qproperty(QString, palette)]
        #[qproperty(bool, reduce_motion)]
        #[qproperty(QString, library_sort)]
        #[qproperty(QString, store_path)]
        #[qproperty(QString, default_store_path)]
        #[qproperty(bool, store_path_is_default)]
        type StateController = super::StateControllerRust;

        /// Persist that the user has seen the welcome card. Idempotent
        /// — calling more than once leaves the original timestamp.
        #[qinvokable]
        fn mark_first_run_seen(self: Pin<&mut StateController>);

        /// Has the user dismissed the named tutorial?
        #[qinvokable]
        fn tutorial_seen(self: Pin<&mut StateController>, name: QString) -> bool;

        /// Mark the named tutorial as dismissed. Persists.
        #[qinvokable]
        fn mark_tutorial_seen(self: Pin<&mut StateController>, name: QString);

        /// Persist the user's theme preference. Accepts "auto",
        /// "light", or "dark"; anything else falls back to "auto".
        /// Named with the `apply_` prefix so it doesn't collide
        /// with the qproperty-generated `set_theme_mode` setter.
        #[qinvokable]
        fn apply_theme_mode(self: Pin<&mut StateController>, mode: QString);

        /// Persist the brand palette. Accepts "warm" or "cool";
        /// anything else falls back to "warm". Same `apply_` prefix
        /// convention as theme_mode.
        #[qinvokable]
        fn apply_palette(self: Pin<&mut StateController>, palette: QString);

        /// Persist the reduce-motion preference. Accepts true or false.
        #[qinvokable]
        fn apply_reduce_motion(self: Pin<&mut StateController>, on: bool);

        /// Persist the default library sort. Accepts "recent", "name",
        /// "last_run"; anything else falls back to "recent".
        #[qinvokable]
        fn apply_library_sort(self: Pin<&mut StateController>, sort: QString);

        /// Reveal the workflows folder in the system file manager.
        /// Best-effort: opens the folder via xdg-open. No-op if the
        /// platform's opener isn't available.
        #[qinvokable]
        fn reveal_store_dir(self: Pin<&mut StateController>);

        /// Set the workflows directory. Empty string clears the
        /// override and falls back to the XDG default. Validates the
        /// path is writable; emits store_path_applied on success and
        /// store_path_rejected with a reason on failure.
        #[qinvokable]
        fn apply_store_path(self: Pin<&mut StateController>, path: QString);

        /// Reset the workflows directory to the XDG default. Equivalent
        /// to `apply_store_path("")` but reads more clearly in QML.
        #[qinvokable]
        fn reset_store_path(self: Pin<&mut StateController>);

        /// Emitted after a successful apply_store_path. The QML side
        /// uses this to refresh the LibraryController so the new path
        /// shows up immediately.
        #[qsignal]
        fn store_path_applied(self: Pin<&mut StateController>);

        /// Emitted when an apply_store_path is rejected. `reason` is
        /// human-readable (e.g. "not writable: permission denied").
        #[qsignal]
        fn store_path_rejected(
            self: Pin<&mut StateController>,
            reason: QString,
        );

        /// Instantiate the named template into the user's library and
        /// return the new workflow id. Empty string on failure.
        #[qinvokable]
        fn create_from_template(
            self: Pin<&mut StateController>,
            template_id: QString,
        ) -> QString;
    }
}

#[derive(Serialize)]
struct TemplateSummary {
    id: String,
    title: String,
    subtitle: String,
}

pub struct StateControllerRust {
    pub is_first_run: bool,
    pub templates_json: QString,
    pub theme_mode: QString,
    pub palette: QString,
    pub reduce_motion: bool,
    pub library_sort: QString,
    pub store_path: QString,
    pub default_store_path: QString,
    pub store_path_is_default: bool,
    inner: state::State,
}

impl Default for StateControllerRust {
    fn default() -> Self {
        let inner = state::load();
        // Install the user's saved override BEFORE we read workflows_dir
        // for display, so the bridge and the engine agree on which
        // folder is in effect from the very first call.
        let override_path: Option<std::path::PathBuf> = inner
            .workflows_dir
            .as_ref()
            .filter(|s| !s.is_empty())
            .map(std::path::PathBuf::from);
        crate::store::set_workflows_dir_override(override_path.clone());

        let templates_json = templates_to_json();
        let theme_mode = QString::from(&inner.theme_mode);
        let palette = QString::from(&inner.palette);
        let library_sort = QString::from(&inner.library_sort);
        let store_path = QString::from(&store_path_display());
        let default_store_path = QString::from(&default_store_path_display());
        let store_path_is_default = override_path.is_none();
        Self {
            is_first_run: inner.is_first_run(),
            templates_json,
            theme_mode,
            palette,
            reduce_motion: inner.reduce_motion,
            library_sort,
            store_path,
            default_store_path,
            store_path_is_default,
            inner,
        }
    }
}

fn store_path_display() -> String {
    crate::store::workflows_dir()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| "(unavailable)".to_string())
}

fn default_store_path_display() -> String {
    crate::store::default_workflows_dir()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| "(unavailable)".to_string())
}

impl qobject::StateController {
    fn mark_first_run_seen(mut self: Pin<&mut Self>) {
        // Borrow the rust-side state, mutate, save, then nudge the
        // qproperty so QML re-binds. CxxQtType brings rust_mut into
        // scope; the rust side is the source of truth, the property
        // is just a mirror for QML reactivity.
        use cxx_qt::CxxQtType;
        let already_seen = !self.as_mut().rust().inner.is_first_run();
        self.as_mut().rust_mut().inner.mark_first_run_seen();
        // Persist whether or not we actually changed the timestamp —
        // mark_first_run_seen is idempotent on the in-memory state.
        let snapshot = self.as_ref().rust().inner.clone();
        state::save(&snapshot);
        if !already_seen {
            self.as_mut().set_is_first_run(false);
        }
    }

    fn tutorial_seen(mut self: Pin<&mut Self>, name: QString) -> bool {
        use cxx_qt::CxxQtType;
        let n: String = name.to_string();
        self.as_mut().rust().inner.tutorial_seen(&n)
    }

    fn mark_tutorial_seen(mut self: Pin<&mut Self>, name: QString) {
        use cxx_qt::CxxQtType;
        let n: String = name.to_string();
        self.as_mut().rust_mut().inner.mark_tutorial_seen(&n);
        let snapshot = self.as_ref().rust().inner.clone();
        state::save(&snapshot);
    }

    fn apply_theme_mode(mut self: Pin<&mut Self>, mode: QString) {
        use cxx_qt::CxxQtType;
        let mut m: String = mode.to_string();
        if m != "auto" && m != "light" && m != "dark" {
            m = "auto".to_string();
        }
        let already = self.as_ref().rust().inner.theme_mode == m;
        self.as_mut().rust_mut().inner.theme_mode = m.clone();
        let snapshot = self.as_ref().rust().inner.clone();
        state::save(&snapshot);
        if !already {
            self.as_mut().set_theme_mode(QString::from(&m));
        }
    }

    fn apply_palette(mut self: Pin<&mut Self>, palette: QString) {
        use cxx_qt::CxxQtType;
        let raw: String = palette.to_string();
        let coerced = if raw != "warm" && raw != "cool" {
            "warm".to_string()
        } else {
            raw.clone()
        };
        let already = self.as_ref().rust().inner.palette == coerced;
        self.as_mut().rust_mut().inner.palette = coerced.clone();
        let snapshot = self.as_ref().rust().inner.clone();
        state::save(&snapshot);
        // Always push the coerced value back to QML when the caller
        // sent something different from what we ended up storing —
        // even if the on-disk value didn't change. Otherwise QML's
        // local mirror keeps the bogus input it eagerly assigned in
        // applyPalette() and the UI desyncs from the persisted state.
        if !already || coerced != raw {
            self.as_mut().set_palette(QString::from(&coerced));
        }
    }

    fn apply_reduce_motion(mut self: Pin<&mut Self>, on: bool) {
        use cxx_qt::CxxQtType;
        let already = self.as_ref().rust().inner.reduce_motion == on;
        self.as_mut().rust_mut().inner.reduce_motion = on;
        let snapshot = self.as_ref().rust().inner.clone();
        state::save(&snapshot);
        if !already {
            self.as_mut().set_reduce_motion(on);
        }
    }

    fn apply_library_sort(mut self: Pin<&mut Self>, sort: QString) {
        use cxx_qt::CxxQtType;
        let mut s: String = sort.to_string();
        if s != "recent" && s != "name" && s != "last_run" {
            s = "recent".to_string();
        }
        let already = self.as_ref().rust().inner.library_sort == s;
        self.as_mut().rust_mut().inner.library_sort = s.clone();
        let snapshot = self.as_ref().rust().inner.clone();
        state::save(&snapshot);
        if !already {
            self.as_mut().set_library_sort(QString::from(&s));
        }
    }

    fn reveal_store_dir(self: Pin<&mut Self>) {
        // Best-effort — open the folder in the user's file manager via
        // xdg-open. Errors are logged, never bubbled up; failing to
        // launch a file manager isn't an app-fatal condition.
        let dir = match crate::store::workflows_dir() {
            Ok(d) => d,
            Err(e) => {
                tracing::warn!("reveal_store_dir: workflows_dir failed: {e:#}");
                return;
            }
        };
        if let Err(e) = std::process::Command::new("xdg-open").arg(&dir).spawn() {
            tracing::warn!(
                "reveal_store_dir: xdg-open {} failed: {e}",
                dir.display()
            );
        }
    }

    fn apply_store_path(mut self: Pin<&mut Self>, path: QString) {
        use cxx_qt::CxxQtType;
        let raw: String = path.to_string();
        let trimmed = raw.trim();

        // Empty path = reset to default.
        if trimmed.is_empty() {
            self.as_mut().reset_store_path();
            return;
        }

        // Expand a leading `~` so users can type "~/Workflows" without
        // having to know the home dir literal. Anything more exotic
        // (env vars, $HOME) is intentionally out of scope.
        let expanded = if let Some(stripped) = trimmed.strip_prefix("~/") {
            if let Some(home) = dirs::home_dir() {
                home.join(stripped)
            } else {
                std::path::PathBuf::from(trimmed)
            }
        } else {
            std::path::PathBuf::from(trimmed)
        };

        if let Err(e) = crate::store::validate_workflows_dir(&expanded) {
            self.as_mut().store_path_rejected(QString::from(&format!("{e}")));
            return;
        }

        // Persist + install + nudge the QML side.
        let display = expanded.to_string_lossy().to_string();
        self.as_mut().rust_mut().inner.workflows_dir = Some(display.clone());
        let snapshot = self.as_ref().rust().inner.clone();
        state::save(&snapshot);
        crate::store::set_workflows_dir_override(Some(expanded));
        self.as_mut().set_store_path(QString::from(&display));
        self.as_mut().set_store_path_is_default(false);
        self.as_mut().store_path_applied();
    }

    fn reset_store_path(mut self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        self.as_mut().rust_mut().inner.workflows_dir = None;
        let snapshot = self.as_ref().rust().inner.clone();
        state::save(&snapshot);
        crate::store::set_workflows_dir_override(None);
        let display = default_store_path_display();
        self.as_mut().set_store_path(QString::from(&display));
        self.as_mut().set_store_path_is_default(true);
        self.as_mut().store_path_applied();
    }

    fn create_from_template(
        self: Pin<&mut Self>,
        template_id: QString,
    ) -> QString {
        let id_s: String = template_id.to_string();
        let template = match templates::discover().into_iter().find(|t| t.id == id_s) {
            Some(t) => t,
            None => {
                tracing::warn!("create_from_template: unknown id {id_s}");
                return QString::from("");
            }
        };

        // Decode the template's KDL through the same path `wflow run`
        // uses, then mint fresh ids so duplicates of the same template
        // get distinct workflow ids.
        let mut wf = match crate::kdl_format::decode(&template.kdl) {
            Ok(w) => w,
            Err(e) => {
                tracing::warn!(
                    "create_from_template: parse {id_s} failed: {e:#}"
                );
                return QString::from("");
            }
        };
        wf.id = uuid::Uuid::new_v4().to_string();
        for step in &mut wf.steps {
            step.id = uuid::Uuid::new_v4().to_string();
        }
        let now = chrono::Utc::now();
        wf.created = Some(now);
        wf.modified = Some(now);
        wf.last_run = None;

        match crate::store::save(wf) {
            Ok(saved) => QString::from(&saved.id),
            Err(e) => {
                tracing::warn!("create_from_template: save failed: {e:#}");
                QString::from("")
            }
        }
    }
}

fn templates_to_json() -> QString {
    let summaries: Vec<TemplateSummary> = templates::discover()
        .into_iter()
        .map(|t| TemplateSummary {
            id: t.id,
            title: t.title,
            subtitle: t.subtitle,
        })
        .collect();
    QString::from(
        &serde_json::to_string(&summaries).unwrap_or_else(|_| "[]".into()),
    )
}
