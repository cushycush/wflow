//! DeeplinkInbox — receives forwarded `wflow://` URLs from second-
//! launch wflow processes and surfaces them to QML's deeplink router.
//!
//! Pairs with `gui_lock.rs`. The first wflow GUI binds the Unix
//! socket and runs a listener thread that pushes URLs through an
//! mpsc::Receiver. Main calls `install_url_receiver` with that
//! Receiver before the QML engine starts; when QML instantiates the
//! singleton DeeplinkInbox, its `start` method takes ownership of
//! the Receiver and spawns a pump thread that emits `url_received`
//! on the Qt thread for each forwarded URL.

use std::pin::Pin;
use std::sync::{Mutex, OnceLock};

use cxx_qt::Threading;
use cxx_qt_lib::QString;

/// Slot for the URL receiver. main.rs writes here once after
/// acquiring the GUI lock; DeeplinkInbox.start reads it once when QML
/// instantiates the singleton. The Mutex<Option<...>> is the
/// canonical "single-shot ownership transfer" shape — `take()`
/// returns None on a second call so a misconfigured QML couldn't
/// double-spawn the pump thread.
static URL_RECEIVER: OnceLock<Mutex<Option<std::sync::mpsc::Receiver<String>>>> = OnceLock::new();

/// Hand the URL receiver from gui_lock over to the bridge layer.
/// Called from main.rs in the lock-holder path before `app.exec()`.
/// No-op (with a warn) when the slot is already populated, which
/// only happens if main.rs is wired wrong.
pub fn install_url_receiver(rx: std::sync::mpsc::Receiver<String>) {
    let slot = URL_RECEIVER.get_or_init(|| Mutex::new(None));
    let mut guard = match slot.lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    };
    if guard.is_some() {
        tracing::warn!("DeeplinkInbox URL receiver already installed; ignoring duplicate");
        return;
    }
    *guard = Some(rx);
}

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
    }

    unsafe extern "RustQt" {
        #[qobject]
        #[qml_element]
        type DeeplinkInbox = super::DeeplinkInboxRust;

        /// Take the URL receiver out of the global slot and start
        /// the pump. QML calls this once on `Component.onCompleted`
        /// for the singleton instance. Idempotent: a second call
        /// finds the slot empty and exits without harm.
        #[qinvokable]
        fn start(self: Pin<&mut DeeplinkInbox>);

        /// Fired on the Qt thread for each URL the listener thread
        /// receives. QML's wflow:// router (Main.qml's
        /// `_resolveDeeplink`) is the only consumer.
        #[qsignal]
        fn url_received(self: Pin<&mut DeeplinkInbox>, url: QString);
    }

    impl cxx_qt::Threading for DeeplinkInbox {}
}

#[derive(Default)]
pub struct DeeplinkInboxRust {}

impl qobject::DeeplinkInbox {
    fn start(self: Pin<&mut Self>) {
        let rx = match URL_RECEIVER.get() {
            Some(slot) => match slot.lock() {
                Ok(mut g) => g.take(),
                Err(p) => p.into_inner().take(),
            },
            None => None,
        };

        let Some(rx) = rx else {
            tracing::debug!(
                "DeeplinkInbox.start: no URL receiver — running without forward inbox"
            );
            return;
        };

        let qt_thread = self.qt_thread();
        std::thread::Builder::new()
            .name("wflow-deeplink-pump".into())
            .spawn(move || {
                while let Ok(url) = rx.recv() {
                    let url_clone = url.clone();
                    let _ = qt_thread.queue(move |mut inbox: Pin<&mut qobject::DeeplinkInbox>| {
                        inbox.as_mut().url_received(QString::from(&url_clone));
                    });
                }
                tracing::info!("DeeplinkInbox pump: receiver closed, exiting");
            })
            .expect("spawn deeplink pump thread");
    }
}
