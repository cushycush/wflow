//! StateController, settings and onboarding state for QML. Persists
//! through `crate::state` (state.toml). Saves are best-effort.

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
        type StateController = super::StateControllerRust;

        #[qinvokable]
        fn mark_first_run_seen(self: Pin<&mut StateController>);

        #[qinvokable]
        fn tutorial_seen(self: Pin<&mut StateController>, name: QString) -> bool;

        #[qinvokable]
        fn mark_tutorial_seen(self: Pin<&mut StateController>, name: QString);

        /// Returns the new workflow id, or empty string on failure.
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
    inner: state::State,
}

impl Default for StateControllerRust {
    fn default() -> Self {
        let inner = state::load();
        let templates_json = templates_to_json();
        Self {
            is_first_run: inner.is_first_run(),
            templates_json,
            inner,
        }
    }
}

impl qobject::StateController {
    fn mark_first_run_seen(mut self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        let already_seen = !self.as_mut().rust().inner.is_first_run();
        self.as_mut().rust_mut().inner.mark_first_run_seen();
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

        // Mint fresh ids so two instances of the same template don't collide.
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
