//! Forwards `wflow://` URLs from second-launch processes onto QML's
//! deeplink router. Pairs with `gui_lock.rs`.

use std::pin::Pin;
use std::sync::{Mutex, OnceLock};

use cxx_qt::Threading;
use cxx_qt_lib::QString;

/// Single-shot ownership transfer: main.rs writes once,
/// DeeplinkInbox.start consumes once.
static URL_RECEIVER: OnceLock<Mutex<Option<std::sync::mpsc::Receiver<String>>>> = OnceLock::new();

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

        /// QML calls this once on `Component.onCompleted`. Idempotent.
        #[qinvokable]
        fn start(self: Pin<&mut DeeplinkInbox>);

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
                "DeeplinkInbox.start: no URL receiver, running without forward inbox"
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
