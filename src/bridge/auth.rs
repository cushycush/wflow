//! Browser-handoff sign-in to wflows.io. State machine:
//! `signed_out → pending → signed_in`, with cancel / sign_out / failure
//! returning to `signed_out`. Token persists in `state.toml`. Flow
//! detail lives in `docs/designs/v1.0-sign-in.md`.

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
        /// `"signed_out" | "pending" | "signed_in" | "failed"`.
        #[qproperty(QString, state)]
        #[qproperty(QString, handle)]
        #[qproperty(QString, display_name)]
        #[qproperty(QString, avatar_url)]
        #[qproperty(QString, last_error)]
        #[qproperty(QString, site_origin)]
        type AuthController = super::AuthControllerRust;

        #[qinvokable]
        fn start_sign_in(self: Pin<&mut AuthController>);

        #[qinvokable]
        fn cancel_sign_in(self: Pin<&mut AuthController>);

        /// Driven by the QML deeplink handler on
        /// `wflow://auth/callback?nonce=...&token=...`.
        #[qinvokable]
        fn complete_sign_in(
            self: Pin<&mut AuthController>,
            nonce: QString,
            token: QString,
        );

        #[qinvokable]
        fn sign_out(self: Pin<&mut AuthController>);

        /// Reload from `state.toml` and re-verify against `/api/v0/me`.
        #[qinvokable]
        fn restore(self: Pin<&mut AuthController>);

        /// Empty string when signed out.
        #[qinvokable]
        fn token(self: Pin<&mut AuthController>) -> QString;

        #[qsignal]
        fn sign_in_succeeded(
            self: Pin<&mut AuthController>,
            handle: QString,
        );

        #[qsignal]
        fn sign_in_failed(
            self: Pin<&mut AuthController>,
            reason: QString,
        );

        #[qsignal]
        fn signed_out_event(self: Pin<&mut AuthController>);
    }

    impl cxx_qt::Threading for AuthController {}
}

pub struct AuthControllerRust {
    pub state: QString,
    pub handle: QString,
    pub display_name: QString,
    pub avatar_url: QString,
    pub last_error: QString,
    pub site_origin: QString,
    /// In-memory only. A stale nonce on disk after a crash is worse
    /// than asking the user to sign in again.
    pending_nonce: String,
    inner: crate::state::State,
}

impl Default for AuthControllerRust {
    fn default() -> Self {
        let inner = crate::state::load();
        let origin = std::env::var("WFLOW_SITE_ORIGIN")
            .unwrap_or_else(|_| "https://wflows.io".to_string());

        let (state, handle, display_name, avatar_url) = match inner.auth.as_ref() {
            Some(snap) => (
                "signed_in".to_string(),
                snap.handle.clone(),
                snap.display_name.clone(),
                snap.avatar_url.clone(),
            ),
            None => ("signed_out".to_string(), String::new(), String::new(), String::new()),
        };

        Self {
            state: QString::from(&state),
            handle: QString::from(&handle),
            display_name: QString::from(&display_name),
            avatar_url: QString::from(&avatar_url),
            last_error: QString::from(""),
            site_origin: QString::from(&origin),
            pending_nonce: String::new(),
            inner,
        }
    }
}

#[derive(serde::Deserialize)]
struct MeResponse {
    handle: String,
    #[serde(default, rename = "displayName")]
    display_name: Option<String>,
    #[serde(default, rename = "avatarUrl")]
    avatar_url: Option<String>,
}

fn http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .user_agent(concat!("wflow/", env!("CARGO_PKG_VERSION")))
        .timeout(std::time::Duration::from_secs(7))
        .build()
        .expect("reqwest client build")
}

impl qobject::AuthController {
    fn start_sign_in(mut self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        let nonce = uuid::Uuid::new_v4().to_string();
        let origin = self.as_ref().rust().site_origin.to_string();
        self.as_mut().rust_mut().pending_nonce = nonce.clone();
        self.as_mut().set_state(QString::from("pending"));
        self.as_mut().set_last_error(QString::from(""));

        let url = format!("{origin}/auth/desktop?nonce={nonce}");
        if let Err(e) = std::process::Command::new("xdg-open").arg(&url).spawn() {
            tracing::warn!("xdg-open {url} failed: {e}");
            self.as_mut().rust_mut().pending_nonce.clear();
            self.as_mut().set_state(QString::from("failed"));
            self.as_mut().set_last_error(QString::from(
                &format!("couldn't open browser: {e}"),
            ));
            self.as_mut()
                .sign_in_failed(QString::from(&format!("couldn't open browser: {e}")));
        }
    }

    fn cancel_sign_in(mut self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        let was_pending = !self.as_ref().rust().pending_nonce.is_empty();
        if !was_pending {
            return;
        }
        self.as_mut().rust_mut().pending_nonce.clear();
        let signed_in = self.as_ref().rust().inner.auth.is_some();
        let next = if signed_in { "signed_in" } else { "signed_out" };
        self.as_mut().set_state(QString::from(next));
        self.as_mut().set_last_error(QString::from(""));
    }

    fn complete_sign_in(
        mut self: Pin<&mut Self>,
        nonce: QString,
        token: QString,
    ) {
        use cxx_qt::CxxQtType;

        let received_nonce = nonce.to_string();
        let token_s = token.to_string();
        let expected_nonce = self.as_ref().rust().pending_nonce.clone();

        // Refuse the callback unless the nonce we minted comes back.
        if expected_nonce.is_empty() {
            self.as_mut().set_state(QString::from("failed"));
            self.as_mut().set_last_error(QString::from(
                "unexpected sign-in callback (no pending request)",
            ));
            self.as_mut()
                .sign_in_failed(QString::from("no pending sign-in"));
            return;
        }
        if received_nonce != expected_nonce {
            self.as_mut().rust_mut().pending_nonce.clear();
            self.as_mut().set_state(QString::from("failed"));
            self.as_mut().set_last_error(QString::from(
                "sign-in nonce mismatch, refusing to install token",
            ));
            self.as_mut().sign_in_failed(QString::from("nonce mismatch"));
            return;
        }
        if token_s.is_empty() {
            self.as_mut().rust_mut().pending_nonce.clear();
            self.as_mut().set_state(QString::from("failed"));
            self.as_mut()
                .set_last_error(QString::from("sign-in returned no token"));
            self.as_mut().sign_in_failed(QString::from("empty token"));
            return;
        }

        // Clear so a replay of the callback fails.
        self.as_mut().rust_mut().pending_nonce.clear();

        // Verify against /api/v0/me before trusting the token.
        let origin = self.as_ref().rust().site_origin.to_string();
        let qt_thread = self.qt_thread();
        let qt_thread = Arc::new(qt_thread);
        let qt_for_outcome = qt_thread.clone();
        tokio::spawn(async move {
            let me_url = format!("{origin}/api/v0/me");
            let outcome = fetch_me(&me_url, &token_s).await;
            let _ = qt_for_outcome.queue(move |mut ctrl: Pin<&mut qobject::AuthController>| {
                use cxx_qt::CxxQtType;
                match outcome {
                    Ok(me) => {
                        let snap = crate::state::AuthSnapshot {
                            token: token_s.clone(),
                            handle: me.handle.clone(),
                            display_name: me.display_name.clone().unwrap_or_default(),
                            avatar_url: me.avatar_url.clone().unwrap_or_default(),
                            signed_in_at: Some(chrono::Utc::now().to_rfc3339()),
                        };
                        ctrl.as_mut().rust_mut().inner.auth = Some(snap.clone());
                        let to_save = ctrl.as_ref().rust().inner.clone();
                        crate::state::save(&to_save);

                        ctrl.as_mut().set_handle(QString::from(&snap.handle));
                        ctrl.as_mut().set_display_name(QString::from(&snap.display_name));
                        ctrl.as_mut().set_avatar_url(QString::from(&snap.avatar_url));
                        ctrl.as_mut().set_state(QString::from("signed_in"));
                        ctrl.as_mut().set_last_error(QString::from(""));
                        ctrl.as_mut().sign_in_succeeded(QString::from(&snap.handle));
                    }
                    Err(reason) => {
                        tracing::warn!(error=%reason, "sign-in /me check failed");
                        ctrl.as_mut().set_state(QString::from("failed"));
                        ctrl.as_mut()
                            .set_last_error(QString::from(&format!("/me failed: {reason}")));
                        ctrl.as_mut()
                            .sign_in_failed(QString::from(&format!("{reason}")));
                    }
                }
            });
        });
    }

    fn sign_out(mut self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        let was_signed_in = self.as_ref().rust().inner.auth.is_some();
        self.as_mut().rust_mut().inner.auth = None;
        let to_save = self.as_ref().rust().inner.clone();
        crate::state::save(&to_save);

        self.as_mut().rust_mut().pending_nonce.clear();
        self.as_mut().set_handle(QString::from(""));
        self.as_mut().set_display_name(QString::from(""));
        self.as_mut().set_avatar_url(QString::from(""));
        self.as_mut().set_state(QString::from("signed_out"));
        self.as_mut().set_last_error(QString::from(""));

        // Open /settings/devices so the user can revoke server-side too.
        if was_signed_in {
            let origin = self.as_ref().rust().site_origin.to_string();
            let url = format!("{origin}/settings/devices");
            let _ = std::process::Command::new("xdg-open").arg(&url).spawn();
        }

        self.as_mut().signed_out_event();
    }

    fn restore(mut self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        // Re-read the snapshot, then verify in the background.
        let inner = crate::state::load();
        self.as_mut().rust_mut().inner = inner;

        let snap = match self.as_ref().rust().inner.auth.clone() {
            Some(s) => s,
            None => {
                self.as_mut().set_state(QString::from("signed_out"));
                self.as_mut().set_handle(QString::from(""));
                self.as_mut().set_display_name(QString::from(""));
                self.as_mut().set_avatar_url(QString::from(""));
                return;
            }
        };

        // Paint cached state immediately; verify in background.
        self.as_mut().set_handle(QString::from(&snap.handle));
        self.as_mut().set_display_name(QString::from(&snap.display_name));
        self.as_mut().set_avatar_url(QString::from(&snap.avatar_url));
        self.as_mut().set_state(QString::from("signed_in"));

        let origin = self.as_ref().rust().site_origin.to_string();
        let token = snap.token.clone();
        let qt_thread = self.qt_thread();
        let qt_thread = Arc::new(qt_thread);
        let qt_for_outcome = qt_thread.clone();
        tokio::spawn(async move {
            let me_url = format!("{origin}/api/v0/me");
            let outcome = fetch_me(&me_url, &token).await;
            let _ = qt_for_outcome.queue(move |mut ctrl: Pin<&mut qobject::AuthController>| {
                use cxx_qt::CxxQtType;
                match outcome {
                    Ok(me) => {
                        // Pick up handle / avatar changes from the web.
                        if let Some(snap) = ctrl.as_mut().rust_mut().inner.auth.as_mut() {
                            snap.handle = me.handle.clone();
                            snap.display_name = me.display_name.clone().unwrap_or_default();
                            snap.avatar_url = me.avatar_url.clone().unwrap_or_default();
                        }
                        let to_save = ctrl.as_ref().rust().inner.clone();
                        crate::state::save(&to_save);

                        ctrl.as_mut().set_handle(QString::from(&me.handle));
                        ctrl.as_mut().set_display_name(
                            QString::from(&me.display_name.unwrap_or_default()),
                        );
                        ctrl.as_mut().set_avatar_url(
                            QString::from(&me.avatar_url.unwrap_or_default()),
                        );
                        ctrl.as_mut().set_state(QString::from("signed_in"));
                    }
                    Err(reason) => {
                        // 401/403 = token rejected, drop it. Network errors
                        // leave the cached snapshot alone (offline use).
                        if reason.contains("401") || reason.contains("403") {
                            tracing::info!(?reason, "stored token rejected; signing out");
                            ctrl.as_mut().rust_mut().inner.auth = None;
                            let to_save = ctrl.as_ref().rust().inner.clone();
                            crate::state::save(&to_save);
                            ctrl.as_mut().set_handle(QString::from(""));
                            ctrl.as_mut().set_display_name(QString::from(""));
                            ctrl.as_mut().set_avatar_url(QString::from(""));
                            ctrl.as_mut().set_state(QString::from("signed_out"));
                            ctrl.as_mut().set_last_error(QString::from(
                                "signed out, token expired or was revoked",
                            ));
                            ctrl.as_mut().signed_out_event();
                        } else {
                            tracing::warn!(?reason, "token verify failed; keeping cached snapshot");
                        }
                    }
                }
            });
        });
    }

    fn token(self: Pin<&mut Self>) -> QString {
        use cxx_qt::CxxQtType;
        match self.as_ref().rust().inner.auth.as_ref() {
            Some(s) => QString::from(&s.token),
            None => QString::from(""),
        }
    }
}

async fn fetch_me(url: &str, token: &str) -> Result<MeResponse, String> {
    let resp = http_client()
        .get(url)
        .bearer_auth(token)
        .send()
        .await
        .map_err(|e| format!("{e}"))?;

    let status = resp.status();
    if !status.is_success() {
        return Err(format!("HTTP {status}"));
    }
    let body = resp.text().await.map_err(|e| format!("{e}"))?;
    serde_json::from_str::<MeResponse>(&body).map_err(|e| format!("parse /me: {e}"))
}
