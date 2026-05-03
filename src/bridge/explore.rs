//! ExploreController — talks to the wflows.com /api/v0 catalog.
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

        /// Import a workflow from `wflows.com` by author handle + slug.
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

        #[qsignal]
        fn import_succeeded(self: Pin<&mut ExploreController>, workflow_id: QString);

        #[qsignal]
        fn import_failed(self: Pin<&mut ExploreController>, reason: QString);

        #[qsignal]
        fn deeplink_preview_ready(
            self: Pin<&mut ExploreController>,
            preview_json: QString,
        );
    }

    impl cxx_qt::Threading for ExploreController {}
}

pub struct ExploreControllerRust {
    pub featured_json: QString,
    pub browse_json: QString,
    pub loading: bool,
    pub last_error: QString,
    pub site_origin: QString,
}

impl Default for ExploreControllerRust {
    fn default() -> Self {
        let origin = std::env::var("WFLOW_SITE_ORIGIN")
            .unwrap_or_else(|_| "https://wflows.com".to_string());
        Self {
            featured_json: QString::from("{\"data\":[]}"),
            browse_json: QString::from("{\"data\":[],\"hasMore\":false}"),
            loading: false,
            last_error: QString::from(""),
            site_origin: QString::from(&origin),
        }
    }
}

fn http_client() -> reqwest::Client {
    // Single shared client so we get connection reuse + the gzip
    // decompressor across all calls. ~7s is generous for a JSON
    // round-trip; the desktop UI shows "loading" so a stalled
    // network reads as "still working" up to that bound.
    reqwest::Client::builder()
        .user_agent(concat!("wflow/", env!("CARGO_PKG_VERSION")))
        .timeout(std::time::Duration::from_secs(7))
        .build()
        .expect("reqwest client build")
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

    fn import_workflow(
        mut self: Pin<&mut Self>,
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

fn urlencoded(s: &str) -> String {
    // Path segments only need a small set escaped; this is the same
    // subset Next.js generates client-side. Anything unusual rejects
    // before reaching here (handles + slugs are validated server-side).
    s.replace('/', "%2F").replace('?', "%3F").replace('#', "%23")
}

fn same_origin(u: &url::Url, origin: &str) -> bool {
    match url::Url::parse(origin) {
        Ok(o) => u.scheme() == o.scheme() && u.host_str() == o.host_str() && u.port() == o.port(),
        Err(_) => false,
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

#[derive(serde::Deserialize)]
struct DetailEnvelope {
    data: DetailData,
}

#[derive(serde::Deserialize)]
struct DetailData {
    #[serde(rename = "kdlSource")]
    kdl_source: String,
    title: String,
    handle: String,
    slug: String,
    /// Catalog "what does this do" blurb. Optional on the wire
    /// (older workflows don't have it) so we deserialise as None
    /// when missing.
    #[serde(default)]
    description: Option<String>,
}

/// Preview payload sent to QML for the confirm dialog. `step_count`
/// is derived from parsing `kdl_source` through the same decoder
/// the run path uses, so it matches what the engine would actually
/// execute — not a byte heuristic.
#[derive(serde::Serialize)]
struct DeeplinkPreview {
    title: String,
    handle: String,
    slug: String,
    description: String,
    #[serde(rename = "stepCount")]
    step_count: usize,
    #[serde(rename = "sourceUrl")]
    source_url: String,
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

async fn fetch_preview(url: &str) -> anyhow::Result<DeeplinkPreview> {
    use anyhow::Context;
    let body = http_client()
        .get(url)
        .send()
        .await
        .with_context(|| format!("GET {url}"))?
        .error_for_status()
        .with_context(|| format!("GET {url}"))?
        .text()
        .await
        .context("read body")?;

    // Preview only meaningful for the v0 detail JSON shape — the
    // /raw KDL endpoint has no metadata to preview. If we got plain
    // KDL, fall back to a minimal preview using the workflow's own
    // title and a step count from the parsed tree, leaving handle /
    // slug / description blank.
    let preview = match serde_json::from_str::<DetailEnvelope>(&body) {
        Ok(env) => {
            let wf = crate::kdl_format::decode(&env.data.kdl_source)
                .context("decode kdl from wflows.com")?;
            DeeplinkPreview {
                title: env.data.title,
                handle: env.data.handle,
                slug: env.data.slug,
                description: env.data.description.unwrap_or_default(),
                step_count: wf.steps.len(),
                source_url: url.to_string(),
            }
        }
        Err(_) => {
            let wf = crate::kdl_format::decode(&body)
                .context("decode raw kdl")?;
            DeeplinkPreview {
                title: wf.title.clone(),
                handle: String::new(),
                slug: String::new(),
                description: wf.subtitle.clone().unwrap_or_default(),
                step_count: wf.steps.len(),
                source_url: url.to_string(),
            }
        }
    };
    Ok(preview)
}

async fn fetch_and_import(url: &str) -> anyhow::Result<String> {
    use anyhow::Context;
    let body = http_client()
        .get(url)
        .send()
        .await
        .with_context(|| format!("GET {url}"))?
        .error_for_status()
        .with_context(|| format!("GET {url}"))?
        .text()
        .await
        .context("read body")?;

    // The /raw endpoint returns plain KDL; the /api/v0/workflow/...
    // endpoint returns JSON with a kdlSource field. Try JSON first
    // (the v0 path is the desktop's preferred entry), fall back to
    // treating the body as raw KDL.
    let (kdl_text, friendly_title): (String, Option<String>) =
        match serde_json::from_str::<DetailEnvelope>(&body) {
            Ok(env) => (env.data.kdl_source.clone(), Some(env.data.title.clone())),
            Err(_) => (body, None),
        };

    let mut wf = crate::kdl_format::decode(&kdl_text)
        .context("decode kdl from wflows.com")?;
    // Mint fresh ids so importing the same workflow twice produces
    // distinct local copies. The remote slug is preserved in the
    // workflow's name so the user can find it.
    wf.id = uuid::Uuid::new_v4().to_string();
    for step in &mut wf.steps {
        step.id = uuid::Uuid::new_v4().to_string();
    }
    if let Some(t) = friendly_title {
        if !t.is_empty() {
            wf.title = t;
        }
    }
    let now = chrono::Utc::now();
    wf.created = Some(now);
    wf.modified = Some(now);
    wf.last_run = None;

    let saved = crate::store::save(wf).context("save imported workflow")?;
    Ok(saved.id)
}
