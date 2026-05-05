//! ExploreController. The wflows.io /api/v0 catalog surface for QML.
//! `WFLOW_SITE_ORIGIN` overrides the default origin for staging runs.

use std::pin::Pin;
use std::sync::Arc;

use cxx_qt::Threading;
use cxx_qt_lib::QString;

use crate::catalog::{
    current_token, fetch_and_import, fetch_detail, fetch_preview, http_client, post_publish,
    same_origin, urlencoded, FetchError, PublishError,
};

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
    }

    unsafe extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[qproperty(QString, featured_json)]
        #[qproperty(QString, browse_json)]
        #[qproperty(QString, favorites_json)]
        #[qproperty(bool, loading)]
        #[qproperty(QString, last_error)]
        #[qproperty(QString, site_origin)]
        type ExploreController = super::ExploreControllerRust;

        #[qinvokable]
        fn fetch_featured(self: Pin<&mut ExploreController>);

        /// Authenticated. Falls back silently when no token is set;
        /// the UI hides the favorites tab in that case. 401 fires
        /// `auth_expired` and sets `last_error`.
        #[qinvokable]
        fn fetch_favorites(self: Pin<&mut ExploreController>);

        /// Empty strings = no filter. Defaults: sort=recent, limit=24.
        /// `offset` clamps to >= 0.
        #[qinvokable]
        fn fetch_browse(
            self: Pin<&mut ExploreController>,
            sort: QString,
            q: QString,
            tag: QString,
            trigger: QString,
            offset: i32,
            limit: i32,
        );

        /// Resolves /api/v0/workflow/:handle/:slug, mints fresh ids,
        /// saves locally. Emits `import_succeeded` or `import_failed`.
        #[qinvokable]
        fn import_workflow(
            self: Pin<&mut ExploreController>,
            handle: QString,
            slug: QString,
        );

        /// `wflow://` deeplink path. Refuses cross-origin URLs.
        #[qinvokable]
        fn import_from_url(self: Pin<&mut ExploreController>, url: QString);

        /// Returns a `wflow://import?source=...` URL captured at startup,
        /// then clears the slot. Subsequent calls return "".
        #[qinvokable]
        fn take_pending_deeplink(self: Pin<&mut ExploreController>) -> QString;

        /// Fetches a deeplink target's detail without writing to disk,
        /// for the confirm dialog. Emits `deeplink_preview_ready` with
        /// `{title, handle, slug, description, stepCount, sourceUrl}`,
        /// or `import_failed` on failure.
        #[qinvokable]
        fn fetch_deeplink_preview(self: Pin<&mut ExploreController>, url: QString);

        /// Catalog-row detail. Parses `kdlSource` through the runner's
        /// decoder so QML sees the exact step list the engine would run.
        #[qinvokable]
        fn fetch_workflow_detail(
            self: Pin<&mut ExploreController>,
            handle: QString,
            slug: QString,
        );

        /// POST /api/v0/workflows. `tags_json` is a JSON string array
        /// (invalid = no tags). `visibility` is "public" | "draft".
        /// 201 → `publish_succeeded(handle, slug, url)`, anything else
        /// → `publish_failed(reason)`. 401 also fires `auth_expired`.
        #[qinvokable]
        fn publish_workflow(
            self: Pin<&mut ExploreController>,
            workflow_id: QString,
            description: QString,
            readme: QString,
            tags_json: QString,
            visibility: QString,
        );

        #[qsignal]
        fn import_succeeded(self: Pin<&mut ExploreController>, workflow_id: QString);

        #[qsignal]
        fn import_failed(self: Pin<&mut ExploreController>, reason: QString);

        #[qsignal]
        fn deeplink_preview_ready(
            self: Pin<&mut ExploreController>,
            preview_json: QString,
        );

        #[qsignal]
        fn workflow_detail_ready(
            self: Pin<&mut ExploreController>,
            detail_json: QString,
        );

        /// Fires on any 401 from an authenticated call. QML wires it
        /// to AuthController.sign_out.
        #[qsignal]
        fn auth_expired(self: Pin<&mut ExploreController>);

        #[qsignal]
        fn publish_succeeded(
            self: Pin<&mut ExploreController>,
            handle: QString,
            slug: QString,
            url: QString,
        );

        #[qsignal]
        fn publish_failed(
            self: Pin<&mut ExploreController>,
            reason: QString,
        );
    }

    impl cxx_qt::Threading for ExploreController {}
}

pub struct ExploreControllerRust {
    pub featured_json: QString,
    pub browse_json: QString,
    pub favorites_json: QString,
    pub loading: bool,
    pub last_error: QString,
    pub site_origin: QString,
}

impl Default for ExploreControllerRust {
    fn default() -> Self {
        // Production lives at wflows.io. `WFLOW_SITE_ORIGIN` overrides
        // for staging or `bun dev` against the wflows.io repo.
        let origin = std::env::var("WFLOW_SITE_ORIGIN")
            .unwrap_or_else(|_| "https://wflows.io".to_string());
        Self {
            featured_json: QString::from("{\"data\":[]}"),
            browse_json: QString::from("{\"data\":[],\"hasMore\":false}"),
            favorites_json: QString::from("{\"data\":[]}"),
            loading: false,
            last_error: QString::from(""),
            site_origin: QString::from(&origin),
        }
    }
}

impl qobject::ExploreController {
    fn fetch_featured(mut self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        let origin = self.as_ref().rust().site_origin.to_string();
        let qt_thread = self.qt_thread();
        self.as_mut().set_loading(true);
        self.as_mut().set_last_error(QString::from(""));

        tokio::spawn(async move {
            let url = format!("{origin}/api/v0/featured");
            let result = http_client()
                .get(&url)
                .send()
                .await
                .and_then(|r| r.error_for_status());

            let outcome = match result {
                Ok(resp) => match resp.text().await {
                    Ok(body) => Ok(body),
                    Err(e) => Err(format!("read failed: {e}")),
                },
                Err(e) => Err(format!("{e}")),
            };

            let _ = qt_thread.queue(move |mut ctrl: Pin<&mut qobject::ExploreController>| {
                ctrl.as_mut().set_loading(false);
                match outcome {
                    Ok(body) => {
                        ctrl.as_mut().set_featured_json(QString::from(&body));
                        ctrl.as_mut().set_last_error(QString::from(""));
                    }
                    Err(e) => {
                        tracing::warn!(error=%e, "fetch_featured failed");
                        ctrl.as_mut().set_last_error(QString::from(&e));
                    }
                }
            });
        });
    }

    fn fetch_browse(
        mut self: Pin<&mut Self>,
        sort: QString,
        q: QString,
        tag: QString,
        trigger: QString,
        offset: i32,
        limit: i32,
    ) {
        use cxx_qt::CxxQtType;
        let origin = self.as_ref().rust().site_origin.to_string();
        let qt_thread = self.qt_thread();
        self.as_mut().set_loading(true);
        self.as_mut().set_last_error(QString::from(""));

        let sort_s = sort.to_string();
        let q_s = q.to_string();
        let tag_s = tag.to_string();
        let trigger_s = trigger.to_string();
        let offset_v = offset.max(0);
        let limit_v = limit.clamp(1, 48);

        tokio::spawn(async move {
            let mut u = match url::Url::parse(&format!("{origin}/api/v0/browse")) {
                Ok(u) => u,
                Err(e) => {
                    let _ = qt_thread.queue(move |mut ctrl: Pin<&mut qobject::ExploreController>| {
                        ctrl.as_mut().set_loading(false);
                        ctrl.as_mut().set_last_error(QString::from(&format!("{e}")));
                    });
                    return;
                }
            };
            {
                let mut qp = u.query_pairs_mut();
                if !sort_s.is_empty() {
                    qp.append_pair("sort", &sort_s);
                }
                if !q_s.is_empty() {
                    qp.append_pair("q", &q_s);
                }
                if !tag_s.is_empty() {
                    qp.append_pair("tag", &tag_s);
                }
                if !trigger_s.is_empty() {
                    qp.append_pair("trigger", &trigger_s);
                }
                qp.append_pair("offset", &offset_v.to_string());
                qp.append_pair("limit", &limit_v.to_string());
            }

            let result = http_client()
                .get(u)
                .send()
                .await
                .and_then(|r| r.error_for_status());

            let outcome = match result {
                Ok(resp) => match resp.text().await {
                    Ok(body) => Ok(body),
                    Err(e) => Err(format!("read failed: {e}")),
                },
                Err(e) => Err(format!("{e}")),
            };

            let _ = qt_thread.queue(move |mut ctrl: Pin<&mut qobject::ExploreController>| {
                ctrl.as_mut().set_loading(false);
                match outcome {
                    Ok(body) => {
                        ctrl.as_mut().set_browse_json(QString::from(&body));
                        ctrl.as_mut().set_last_error(QString::from(""));
                    }
                    Err(e) => {
                        tracing::warn!(error=%e, "fetch_browse failed");
                        ctrl.as_mut().set_last_error(QString::from(&e));
                    }
                }
            });
        });
    }

    fn fetch_favorites(mut self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        let origin = self.as_ref().rust().site_origin.to_string();
        let qt_thread = self.qt_thread();
        self.as_mut().set_loading(true);
        self.as_mut().set_last_error(QString::from(""));

        let token = match current_token() {
            Some(t) => t,
            None => {
                self.as_mut().set_loading(false);
                self.as_mut().set_last_error(QString::from(
                    "favorites: not signed in",
                ));
                return;
            }
        };

        tokio::spawn(async move {
            let url = format!("{origin}/api/v0/favorites");
            let outcome: Result<String, FetchError> = match http_client()
                .get(&url)
                .bearer_auth(&token)
                .send()
                .await
            {
                Ok(resp) => {
                    if resp.status() == reqwest::StatusCode::UNAUTHORIZED {
                        Err(FetchError::Unauthorized)
                    } else if !resp.status().is_success() {
                        Err(FetchError::Other(format!("HTTP {}", resp.status())))
                    } else {
                        match resp.text().await {
                            Ok(body) => Ok(body),
                            Err(e) => Err(FetchError::Other(format!("read failed: {e}"))),
                        }
                    }
                }
                Err(e) => Err(FetchError::Other(format!("{e}"))),
            };

            let _ = qt_thread.queue(move |mut ctrl: Pin<&mut qobject::ExploreController>| {
                ctrl.as_mut().set_loading(false);
                match outcome {
                    Ok(body) => {
                        ctrl.as_mut().set_favorites_json(QString::from(&body));
                        ctrl.as_mut().set_last_error(QString::from(""));
                    }
                    Err(FetchError::Unauthorized) => {
                        tracing::info!("favorites: 401, token rejected");
                        ctrl.as_mut().set_favorites_json(QString::from("{\"data\":[]}"));
                        ctrl.as_mut().set_last_error(QString::from(
                            "signed out, token expired or was revoked",
                        ));
                        ctrl.as_mut().auth_expired();
                    }
                    Err(FetchError::Other(e)) => {
                        tracing::warn!(error=%e, "fetch_favorites failed");
                        ctrl.as_mut().set_last_error(QString::from(&e));
                    }
                }
            });
        });
    }

    fn import_workflow(
        self: Pin<&mut Self>,
        handle: QString,
        slug: QString,
    ) {
        use cxx_qt::CxxQtType;
        let origin = self.as_ref().rust().site_origin.to_string();
        let qt_thread = self.qt_thread();
        let handle_s = handle.to_string();
        let slug_s = slug.to_string();
        let url = format!(
            "{origin}/api/v0/workflow/{}/{}",
            urlencoded(&handle_s),
            urlencoded(&slug_s),
        );
        spawn_import(qt_thread, url, Some(origin));
    }

    fn publish_workflow(
        mut self: Pin<&mut Self>,
        workflow_id: QString,
        description: QString,
        readme: QString,
        tags_json: QString,
        visibility: QString,
    ) {
        use cxx_qt::CxxQtType;
        let origin = self.as_ref().rust().site_origin.to_string();
        let qt_thread = self.qt_thread();
        self.as_mut().set_loading(true);
        self.as_mut().set_last_error(QString::from(""));

        let id_s = workflow_id.to_string();
        let description_s = description.to_string();
        let readme_s = readme.to_string();
        let tags_json_s = tags_json.to_string();
        let visibility_s = visibility.to_string();

        let token = match current_token() {
            Some(t) => t,
            None => {
                self.as_mut().set_loading(false);
                self.as_mut().set_last_error(QString::from(
                    "publish: not signed in",
                ));
                self.as_mut()
                    .publish_failed(QString::from("not signed in"));
                return;
            }
        };

        // KDL encode is sync; do it inline so missing workflows fail
        // before we commit a tokio task.
        let kdl = match crate::store::export_kdl(&id_s) {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(?e, "publish: export_kdl {id_s} failed");
                self.as_mut().set_loading(false);
                let msg = format!("couldn't read workflow: {e}");
                self.as_mut().set_last_error(QString::from(&msg));
                self.as_mut().publish_failed(QString::from(&msg));
                return;
            }
        };

        let tags: Vec<String> = serde_json::from_str(&tags_json_s).unwrap_or_default();
        let visibility = if visibility_s == "draft" { "draft" } else { "public" };

        let body = serde_json::json!({
            "kdl": kdl,
            "description": description_s,
            "readme": readme_s,
            "tags": tags,
            "visibility": visibility,
        });

        tokio::spawn(async move {
            let url = format!("{origin}/api/v0/workflows");
            let outcome = post_publish(&url, &token, &body).await;
            let _ = qt_thread.queue(move |mut ctrl: Pin<&mut qobject::ExploreController>| {
                ctrl.as_mut().set_loading(false);
                match outcome {
                    Ok(p) => {
                        ctrl.as_mut().set_last_error(QString::from(""));
                        ctrl.as_mut().publish_succeeded(
                            QString::from(&p.handle),
                            QString::from(&p.slug),
                            QString::from(&p.url),
                        );
                    }
                    Err(PublishError::Unauthorized) => {
                        tracing::info!("publish: 401, token rejected");
                        ctrl.as_mut().set_last_error(QString::from(
                            "signed out, token expired or was revoked",
                        ));
                        ctrl.as_mut().auth_expired();
                        ctrl.as_mut().publish_failed(QString::from(
                            "not signed in",
                        ));
                    }
                    Err(PublishError::Other(reason)) => {
                        tracing::warn!(error=%reason, "publish failed");
                        ctrl.as_mut().set_last_error(QString::from(&reason));
                        ctrl.as_mut().publish_failed(QString::from(&reason));
                    }
                }
            });
        });
    }

    fn take_pending_deeplink(self: Pin<&mut Self>) -> QString {
        // Single-shot: clear the env var so a re-poll returns empty.
        let url = std::env::var("WFLOW_PENDING_DEEPLINK").unwrap_or_default();
        if !url.is_empty() {
            std::env::remove_var("WFLOW_PENDING_DEEPLINK");
        }
        QString::from(&url)
    }

    fn import_from_url(mut self: Pin<&mut Self>, url: QString) {
        let _ = &mut self;
        let origin = {
            use cxx_qt::CxxQtType;
            self.as_ref().rust().site_origin.to_string()
        };
        let qt_thread = self.qt_thread();
        let url_s = url.to_string();

        // Hard origin fence; the deeplink path is the browser handing
        // us a URL.
        match url::Url::parse(&url_s) {
            Ok(u) => {
                if !same_origin(&u, &origin) {
                    let _ = qt_thread.queue(move |mut ctrl: Pin<&mut qobject::ExploreController>| {
                        ctrl.as_mut().import_failed(QString::from(
                            &format!("refused: import URL must be on {origin}"),
                        ));
                    });
                    return;
                }
            }
            Err(e) => {
                let _ = qt_thread.queue(move |mut ctrl: Pin<&mut qobject::ExploreController>| {
                    ctrl.as_mut().import_failed(QString::from(&format!("invalid url: {e}")));
                });
                return;
            }
        }

        spawn_import(qt_thread, url_s, Some(origin));
    }

    fn fetch_workflow_detail(
        self: Pin<&mut Self>,
        handle: QString,
        slug: QString,
    ) {
        let origin = {
            use cxx_qt::CxxQtType;
            self.as_ref().rust().site_origin.to_string()
        };
        let qt_thread = self.qt_thread();
        let handle_s = handle.to_string();
        let slug_s = slug.to_string();
        let url = format!(
            "{origin}/api/v0/workflow/{}/{}",
            urlencoded(&handle_s),
            urlencoded(&slug_s),
        );
        spawn_detail(qt_thread, url);
    }

    fn fetch_deeplink_preview(self: Pin<&mut Self>, url: QString) {
        let origin = {
            use cxx_qt::CxxQtType;
            self.as_ref().rust().site_origin.to_string()
        };
        let qt_thread = self.qt_thread();
        let url_s = url.to_string();

        // Same origin fence as the install path.
        match url::Url::parse(&url_s) {
            Ok(u) => {
                if !same_origin(&u, &origin) {
                    let _ = qt_thread.queue(move |mut ctrl: Pin<&mut qobject::ExploreController>| {
                        ctrl.as_mut().import_failed(QString::from(
                            &format!("refused: import URL must be on {origin}"),
                        ));
                    });
                    return;
                }
            }
            Err(e) => {
                let _ = qt_thread.queue(move |mut ctrl: Pin<&mut qobject::ExploreController>| {
                    ctrl.as_mut().import_failed(QString::from(&format!("invalid url: {e}")));
                });
                return;
            }
        }

        spawn_preview(qt_thread, url_s);
    }
}

fn spawn_import(
    qt_thread: cxx_qt::CxxQtThread<qobject::ExploreController>,
    url: String,
    _origin: Option<String>,
) {
    let qt_thread = Arc::new(qt_thread);
    let qt_for_outcome = qt_thread.clone();
    tokio::spawn(async move {
        let outcome = match fetch_and_import(&url).await {
            Ok(id) => Ok(id),
            Err(e) => Err(format!("{e}")),
        };
        let _ = qt_for_outcome.queue(move |mut ctrl: Pin<&mut qobject::ExploreController>| {
            match outcome {
                Ok(id) => ctrl.as_mut().import_succeeded(QString::from(&id)),
                Err(reason) => {
                    tracing::warn!(error=%reason, "import_workflow failed");
                    ctrl.as_mut().import_failed(QString::from(&reason));
                }
            }
        });
    });
}

fn spawn_preview(
    qt_thread: cxx_qt::CxxQtThread<qobject::ExploreController>,
    url: String,
) {
    let qt_thread = Arc::new(qt_thread);
    let qt_for_outcome = qt_thread.clone();
    tokio::spawn(async move {
        let outcome = match fetch_preview(&url).await {
            Ok(preview) => Ok(preview),
            Err(e) => Err(format!("{e}")),
        };
        let _ = qt_for_outcome.queue(move |mut ctrl: Pin<&mut qobject::ExploreController>| {
            match outcome {
                Ok(preview) => match serde_json::to_string(&preview) {
                    Ok(json) => ctrl.as_mut().deeplink_preview_ready(QString::from(&json)),
                    Err(e) => {
                        tracing::warn!(error=%e, "preview json serialise failed");
                        ctrl.as_mut().import_failed(QString::from(
                            &format!("preview encode failed: {e}"),
                        ));
                    }
                },
                Err(reason) => {
                    tracing::warn!(error=%reason, "deeplink preview failed");
                    ctrl.as_mut().import_failed(QString::from(&reason));
                }
            }
        });
    });
}


fn spawn_detail(
    qt_thread: cxx_qt::CxxQtThread<qobject::ExploreController>,
    url: String,
) {
    let qt_thread = Arc::new(qt_thread);
    let qt_for_outcome = qt_thread.clone();
    tokio::spawn(async move {
        let outcome = fetch_detail(&url).await.map_err(|e| format!("{e}"));
        let _ = qt_for_outcome.queue(move |mut ctrl: Pin<&mut qobject::ExploreController>| {
            match outcome {
                Ok(detail) => match serde_json::to_string(&detail) {
                    Ok(json) => ctrl.as_mut().workflow_detail_ready(QString::from(&json)),
                    Err(e) => {
                        tracing::warn!(error=%e, "detail json serialise failed");
                        ctrl.as_mut()
                            .import_failed(QString::from(&format!("detail encode failed: {e}")));
                    }
                },
                Err(reason) => {
                    tracing::warn!(error=%reason, "fetch_workflow_detail failed");
                    ctrl.as_mut().import_failed(QString::from(&reason));
                }
            }
        });
    });
}
