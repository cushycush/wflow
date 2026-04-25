//! RecorderController — Record Mode state machine exposed to QML.
//!
//! Wraps `recorder::Recorder` and pumps its `RecFrame` stream back onto
//! the Qt thread as property changes and signals.

use std::pin::Pin;
use std::sync::Arc;
use std::time::Instant;

use cxx_qt::{CxxQtType, Threading};
use cxx_qt_lib::QString;
use tokio::sync::Mutex;

use crate::actions::Workflow;
use crate::recorder::{self, RecEvent, RecFrame};
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
        #[qproperty(QString, state)] // "idle" | "armed" | "recording" | "stopped"
        #[qproperty(i32, event_count)]
        #[qproperty(i32, elapsed_ms)]
        #[qproperty(QString, events_json)]
        #[qproperty(QString, last_error)]
        type RecorderController = super::RecorderControllerRust;

        /// Begin a recording session (simulated today — see recorder.rs).
        #[qinvokable]
        fn arm(self: Pin<&mut RecorderController>);

        /// Stop the current session. `events_json` now contains the stream.
        #[qinvokable]
        fn stop(self: Pin<&mut RecorderController>);

        /// Turn the captured events into a saved workflow. Returns its id.
        /// Only valid after a stop. Returns "" if there's nothing to save.
        #[qinvokable]
        fn finalize(self: Pin<&mut RecorderController>, title: QString) -> QString;

        /// Each captured event, one fire per frame.
        #[qsignal]
        fn event_captured(
            self: Pin<&mut RecorderController>,
            kind: QString,
            t_ms: i32,
            summary: QString,
        );
    }

    impl cxx_qt::Threading for RecorderController {}
}

pub struct RecorderControllerRust {
    pub state: QString,
    pub event_count: i32,
    pub elapsed_ms: i32,
    pub events_json: QString,
    pub last_error: QString,
    pub(super) inner: Arc<recorder::Recorder>,
    pub(super) captured: Arc<Mutex<Vec<RecEvent>>>,
    pub(super) armed_at: Option<Instant>,
}

impl Default for RecorderControllerRust {
    fn default() -> Self {
        Self {
            state: QString::from("idle"),
            event_count: 0,
            elapsed_ms: 0,
            events_json: QString::from("[]"),
            last_error: QString::from(""),
            inner: Arc::new(recorder::Recorder::new()),
            captured: Default::default(),
            armed_at: None,
        }
    }
}

impl qobject::RecorderController {
    fn arm(mut self: Pin<&mut Self>) {
        if self.state.to_string() != "idle" {
            return;
        }
        self.as_mut().set_last_error(QString::from(""));
        self.as_mut().set_event_count(0);
        self.as_mut().set_elapsed_ms(0);
        self.as_mut().set_events_json(QString::from("[]"));

        let qt_thread = self.qt_thread();
        let captured = {
            let mut r = self.as_mut().rust_mut();
            r.captured = Default::default();
            r.armed_at = Some(Instant::now());
            r.captured.clone()
        };

        let inner = self.as_mut().rust_mut().inner.clone();
        let sink: recorder::FrameSink = Arc::new(move |frame: RecFrame| {
            let thread = qt_thread.clone();
            let captured = captured.clone();
            match frame {
                RecFrame::Armed => {
                    let _ = thread.queue(|mut ctrl: Pin<&mut qobject::RecorderController>| {
                        ctrl.as_mut().set_state(QString::from("armed"));
                    });
                }
                RecFrame::Started => {
                    let _ = thread.queue(|mut ctrl: Pin<&mut qobject::RecorderController>| {
                        ctrl.as_mut().set_state(QString::from("recording"));
                    });
                }
                RecFrame::Event { event } => {
                    let t_ms = event.t_ms() as i32;
                    let (kind, summary) = summarize(&event);
                    // Stash synchronously for later finalize.
                    let ev_clone = event.clone();
                    tokio::spawn({
                        let captured = captured.clone();
                        async move {
                            captured.lock().await.push(ev_clone);
                        }
                    });
                    let _ = thread.queue(move |mut ctrl: Pin<&mut qobject::RecorderController>| {
                        let n = ctrl.as_ref().event_count + 1;
                        ctrl.as_mut().set_event_count(n);
                        ctrl.as_mut().set_elapsed_ms(t_ms);
                        ctrl.as_mut().event_captured(
                            QString::from(&kind),
                            t_ms,
                            QString::from(&summary),
                        );
                    });
                }
                RecFrame::Stopped { total_ms, .. } => {
                    let total = total_ms as i32;
                    let captured = captured.clone();
                    let _ = thread.queue(move |mut ctrl: Pin<&mut qobject::RecorderController>| {
                        ctrl.as_mut().set_state(QString::from("stopped"));
                        ctrl.as_mut().set_elapsed_ms(total);
                        // Flush the JSON snapshot once the session has settled.
                        let captured = captured.clone();
                        let thread2 = ctrl.qt_thread();
                        tokio::spawn(async move {
                            let events = captured.lock().await.clone();
                            let json = serde_json::to_string(&events)
                                .unwrap_or_else(|_| "[]".into());
                            let _ = thread2.queue(
                                move |mut ctrl: Pin<&mut qobject::RecorderController>| {
                                    ctrl.as_mut().set_events_json(QString::from(&json));
                                },
                            );
                        });
                    });
                }
            }
        });

        let err_qt_thread = self.qt_thread();
        tokio::spawn(async move {
            if let Err(e) = inner.start(sink.clone()).await {
                tracing::warn!(?e, "recorder::start failed");
                let msg = format!("{e:#}");
                let _ = err_qt_thread.queue(move |mut ctrl: Pin<&mut qobject::RecorderController>| {
                    ctrl.as_mut().set_state(QString::from("idle"));
                    ctrl.as_mut().set_last_error(QString::from(&msg));
                });
            }
        });
    }

    fn stop(mut self: Pin<&mut Self>) {
        let s = self.state.to_string();
        if s != "armed" && s != "recording" {
            return;
        }
        let inner = self.as_mut().rust_mut().inner.clone();
        let qt_thread = self.qt_thread();
        let captured = self.as_mut().rust_mut().captured.clone();
        tokio::spawn(async move {
            let stop_sink: recorder::FrameSink = Arc::new(move |frame: RecFrame| {
                if let RecFrame::Stopped { total_ms, .. } = frame {
                    let total = total_ms as i32;
                    let captured = captured.clone();
                    let _ = qt_thread.queue(move |mut ctrl: Pin<&mut qobject::RecorderController>| {
                        ctrl.as_mut().set_state(QString::from("stopped"));
                        ctrl.as_mut().set_elapsed_ms(total);
                        let captured = captured.clone();
                        let thread2 = ctrl.qt_thread();
                        tokio::spawn(async move {
                            let events = captured.lock().await.clone();
                            let json = serde_json::to_string(&events)
                                .unwrap_or_else(|_| "[]".into());
                            let _ = thread2.queue(
                                move |mut ctrl: Pin<&mut qobject::RecorderController>| {
                                    ctrl.as_mut().set_events_json(QString::from(&json));
                                },
                            );
                        });
                    });
                }
            });
            let _ = inner.stop(stop_sink, "user").await;
        });
    }

    fn finalize(mut self: Pin<&mut Self>, title: QString) -> QString {
        let title_s: String = title.to_string();
        let title_s = if title_s.trim().is_empty() {
            "Recorded workflow".into()
        } else {
            title_s
        };
        let captured = self.as_mut().rust_mut().captured.clone();
        // Block on just long enough to read the captured buffer (cheap).
        let events: Vec<RecEvent> =
            tokio::task::block_in_place(|| tokio::runtime::Handle::current().block_on(async {
                captured.lock().await.clone()
            }));
        if events.is_empty() {
            return QString::from("");
        }
        let wf: Workflow = recorder::events_to_workflow(&events, &title_s);
        match store::save(wf) {
            Ok(saved) => {
                // Reset state so the Record page can show "ready to record again".
                self.as_mut().set_state(QString::from("idle"));
                self.as_mut().set_event_count(0);
                self.as_mut().set_elapsed_ms(0);
                self.as_mut().set_events_json(QString::from("[]"));
                QString::from(&saved.id)
            }
            Err(e) => {
                tracing::warn!(?e, "finalize save failed");
                self.as_mut().set_last_error(QString::from(&format!("{e:#}")));
                QString::from("")
            }
        }
    }
}

fn summarize(ev: &RecEvent) -> (String, String) {
    match ev {
        RecEvent::Key { chord, .. } => ("key".into(), chord.clone()),
        RecEvent::Text { text, .. } => ("type".into(), text.clone()),
        RecEvent::Click { button, .. } => ("click".into(), format!("button {button}")),
        RecEvent::Move { x, y, .. } => ("move".into(), format!("({x}, {y})")),
        RecEvent::Scroll { dx, dy, .. } => ("scroll".into(), format!("dx {dx} dy {dy}")),
        RecEvent::WindowFocus { name, .. } => ("focus".into(), name.clone()),
        RecEvent::Gap { ms, .. } => ("wait".into(), format!("{ms} ms")),
    }
}
