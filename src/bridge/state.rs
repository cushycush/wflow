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
    inner: state::State,
}

impl Default for StateControllerRust {
    fn default() -> Self {
        let inner = state::load();
        let templates_json = templates_to_json();
        let theme_mode = QString::from(&inner.theme_mode);
        Self {
            is_first_run: inner.is_first_run(),
            templates_json,
            theme_mode,
            inner,
        }
    }
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
