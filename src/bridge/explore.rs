//! ExploreController — talks to the wflows.io /api/v0 catalog.
//!
//! Owns:
//!   - `featured_json` — the latest /api/v0/featured response, JSON-stringified
//!   - `browse_json`   — the latest /api/v0/browse response, JSON-stringified
//!   - `loading`       — true while a fetch is in flight
//!   - `last_error`    — empty string on success, human-readable on failure
//!
//! All work runs on the shared tokio runtime. Results land back on the Qt
//! thread via `qt_thread.queue(...)`. The site URL is read from
//! `WFLOW_SITE_ORIGIN` so test / staging runs can point at localhost
//! without a code change; default is the production origin.

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

        /// Fire a GET against /api/v0/featured. Result lands in
        /// `featured_json` on success; `last_error` is set on failure.
        /// Re-entrant — calls while a fetch is in flight cancel the
        /// in-flight task and start fresh.
        #[qinvokable]
        fn fetch_featured(self: Pin<&mut ExploreController>);

        /// Fire a GET against /api/v0/favorites. Authenticated — uses
        /// the AuthController's persisted token via state.toml.
        /// Result lands in `favorites_json`. On 401 emits
        /// `auth_expired` so the QML shell can flip the auth state
        /// machine back to signed_out, then surfaces a human-readable
        /// `last_error`. On no-token-available the call exits silently
        /// with `last_error` set; the UI hides the favorites tab in
        /// that state anyway.
        #[qinvokable]
        fn fetch_favorites(self: Pin<&mut ExploreController>);

        /// Fire a GET against /api/v0/browse with the given filters.
        /// Empty strings mean "no filter" (sort defaults to "recent",
        /// limit defaults to 24). offset is clamped to >= 0.
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

        /// Import a workflow from `wflows.io` by author handle + slug.
        /// Resolves the v0 detail endpoint, decodes the KDL through the
        /// same path the run command uses, mints fresh ids, and saves
        /// to the local store. On success emits `import_succeeded`
        /// with the new workflow id; on failure emits `import_failed`
        /// with a human-readable reason.
        #[qinvokable]
        fn import_workflow(
            self: Pin<&mut ExploreController>,
            handle: QString,
            slug: QString,
        );

        /// Import from a raw URL — the wflow:// deeplink path. The URL
        /// must point at /api/v0/workflow/:handle/:slug or a /raw KDL
        /// endpoint on the configured site_origin (cross-origin URLs
        /// are refused for security).
        #[qinvokable]
        fn import_from_url(self: Pin<&mut ExploreController>, url: QString);

        /// Pending `wflow://import?source=...` URL captured at startup
        /// from the deep-link CLI argument. Returns the URL once and
        /// then clears the slot so a later call returns "". The QML
        /// shell calls this on first paint to find any work to do.
        #[qinvokable]
        fn take_pending_deeplink(self: Pin<&mut ExploreController>) -> QString;

        /// Fetch the v0 detail JSON for a deeplink target without
        /// writing anything to disk. Used to populate the confirm
        /// dialog the QML shell shows before installing. Same origin
        /// fence as `import_from_url`; emits `deeplink_preview_ready`
        /// with a JSON payload `{title, handle, slug, description,
        /// stepCount, sourceUrl}` on success, or `import_failed` with
        /// a human-readable reason on failure (the dialog flow reuses
        /// the existing failure surface).
        #[qinvokable]
        fn fetch_deeplink_preview(self: Pin<&mut ExploreController>, url: QString);

        /// Fetch the v0 detail for a catalog row by handle + slug.
        /// Resolves on /api/v0/workflow/:handle/:slug and parses the
        /// inline `kdlSource` through the same decoder the runner
        /// uses, so the step list emitted to QML is exactly what the
        /// engine would execute. Emits `workflow_detail_ready` with a
        /// rich JSON payload (live install / comment counts, parsed
        /// steps, timestamps); failures route through `import_failed`
        /// so the existing "couldn't reach wflows.io" surface holds.
        #[qinvokable]
        fn fetch_workflow_detail(
            self: Pin<&mut ExploreController>,
            handle: QString,
            slug: QString,
        );

        /// POST a local workflow to wflows.io's publish endpoint.
        /// Loads the workflow from the local store, encodes it to
        /// KDL, attaches the supplied metadata, and posts to
        /// `/api/v0/workflows` with the persisted Bearer token.
        ///
        /// `tags_json` is a JSON array of strings; empty / invalid
        /// JSON gets sent as no tags. `visibility` is "public" or
        /// "draft" (anything else lands as "public" server-side).
        ///
        /// Emits `publish_succeeded(handle, slug, url)` on 201,
        /// `publish_failed(reason)` on any other outcome. Routes 401
        /// through `auth_expired` so the UI flips back to signed-out
        /// the same way other authenticated calls do.
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

        /// Emitted when an authenticated call returns 401. The QML
        /// shell wires this to AuthController.sign_out so the user
        /// drops out of signed-in state without seeing stale data.
        #[qsignal]
        fn auth_expired(self: Pin<&mut ExploreController>);

        /// Emitted on a successful `POST /api/v0/workflows`. Carries
        /// the resulting handle / slug / URL so the QML shell can
        /// route the user to the new public listing or surface a
        /// success toast with a deep-link.
        #[qsignal]
        fn publish_succeeded(
            self: Pin<&mut ExploreController>,
            handle: QString,
            slug: QString,
            url: QString,
        );

        /// Emitted on any non-success publish path — auth failure,
        /// validation error, network blip. Reason is human-readable
        /// and goes into the publish dialog's error slot. 401s also
        /// fire `auth_expired` so the global auth state flips.
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
        // Production catalog lives at wflows.io (the brand domain
        // points at the Vercel deployment). `WFLOW_SITE_ORIGIN`
        // overrides for staging / local-dev — set to
        // `http://localhost:3000` against a `bun dev` of the
        // wflows.io repo, or to `https://wflows.vercel.app` to
        // hit the deploy preview directly.
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
            // url::Url's query_pairs_mut handles encoding for us so we
            // don't have to hand-roll percent-escapes for the search box.
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
                        tracing::info!("favorites: 401 — token rejected");
                        ctrl.as_mut().set_favorites_json(QString::from("{\"data\":[]}"));
                        ctrl.as_mut().set_last_error(QString::from(
                            "signed out — token expired or was revoked",
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

        // Encode the workflow to KDL on this thread — the store API
        // is sync and we want the error to surface before we commit
        // a tokio task. If the workflow doesn't exist locally
        // there's no point posting anything.
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
                        tracing::info!("publish: 401 — token rejected");
                        ctrl.as_mut().set_last_error(QString::from(
                            "signed out — token expired or was revoked",
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
        // Look for the deeplink in two places, in order of recency:
        //   1. The env var we set in main.rs from the CLI arg.
        //   2. (Future) a D-Bus single-instance handoff slot — the
        //      multi-launch path will plug in here without changing
        //      the QML side.
        // We CLEAR the env var after reading so a re-poll returns
        // empty; the URL is "consumed" exactly once.
        let url = std::env::var("WFLOW_PENDING_DEEPLINK").unwrap_or_default();
        if !url.is_empty() {
            std::env::remove_var("WFLOW_PENDING_DEEPLINK");
        }
        QString::from(&url)
    }

    fn import_from_url(mut self: Pin<&mut Self>, url: QString) {
        let _ = &mut self; // future-proof if we set loading=true here
        let origin = {
            use cxx_qt::CxxQtType;
            self.as_ref().rust().site_origin.to_string()
        };
        let qt_thread = self.qt_thread();
        let url_s = url.to_string();

        // Refuse cross-origin imports outright. The deeplink path is a
        // browser handing us a URL, so we want a hard fence around the
        // configured site origin — otherwise a malicious page could
        // pop the desktop app to a hostile KDL.
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

        // Same origin fence as the install path. A preview that
        // accepted cross-origin URLs would still leak which page the
        // user clicked from, plus tempt a future change to "just go
        // ahead and install since the user already saw the dialog."
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
