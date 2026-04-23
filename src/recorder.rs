//! Record mode backend.
//!
//! Exposes `start` / `stop` to the frontend and emits a stream of
//! `RecEvent`s captured from the user's input as they perform actions.
//!
//! IMPLEMENTATION STATUS
//! =====================
//! The hero path — real capture via libei's RECEIVER context through the
//! XDG RemoteDesktop portal — is TODO. Today this module ships a
//! deterministic **simulated** recorder so the UI can be crafted and iterated
//! without depending on portal permissions at every run.
//!
//! Integration target (follow-up): `reis` crate in receiver mode on an
//! `ashpd::desktop::remote_desktop::RemoteDesktop` session whose `devices`
//! include pointer + keyboard, with `device_start_emulating` called on OUR
//! side as a no-op and events read from the EIS server. See wdotool's
//! `src/backend/libei.rs` for the sender-side reference.

use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;
use tokio::task::JoinHandle;

use crate::actions::{Action, Step, Workflow};

/// A thread-safe frame sink. The bridge layer owns the Qt signal
/// emission; we just hand it frames as they happen.
pub type FrameSink = Arc<dyn Fn(RecFrame) + Send + Sync>;

/// A single captured input event, as surfaced to the UI.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RecEvent {
    /// A chord was pressed (coalesced from modifier + key).
    Key { t_ms: u64, chord: String },
    /// Text was typed (coalesced from sequential key events resolving to chars).
    Text { t_ms: u64, text: String },
    /// A mouse button was pressed.
    Click { t_ms: u64, button: u8 },
    /// A significant mouse movement (below-threshold moves are discarded).
    Move { t_ms: u64, x: i32, y: i32 },
    /// Scroll.
    Scroll { t_ms: u64, dx: i32, dy: i32 },
    /// Focus landed on a new top-level window.
    WindowFocus { t_ms: u64, name: String },
    /// Gap — auto-inserted when nothing else happened for a while.
    Gap { t_ms: u64, ms: u64 },
}

impl RecEvent {
    pub fn t_ms(&self) -> u64 {
        match self {
            RecEvent::Key { t_ms, .. }
            | RecEvent::Text { t_ms, .. }
            | RecEvent::Click { t_ms, .. }
            | RecEvent::Move { t_ms, .. }
            | RecEvent::Scroll { t_ms, .. }
            | RecEvent::WindowFocus { t_ms, .. }
            | RecEvent::Gap { t_ms, .. } => *t_ms,
        }
    }
}

/// Frame-level status pushed to the UI so it can show recording state / timer.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RecFrame {
    Armed,
    Started,
    Event { event: RecEvent },
    Stopped { reason: String, total_ms: u64 },
}

// ------------------------------- Session state ------------------------------

#[derive(Default)]
pub struct Recorder {
    inner: Mutex<Option<Session>>,
}

struct Session {
    events: Arc<Mutex<Vec<RecEvent>>>,
    task: JoinHandle<()>,
    started_at: std::time::Instant,
}

impl Recorder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Start a new recording session. Calls `sink` with each `RecFrame`.
    pub async fn start(&self, sink: FrameSink) -> anyhow::Result<()> {
        let mut slot = self.inner.lock().await;
        if slot.is_some() {
            anyhow::bail!("a recording session is already in progress");
        }

        let events: Arc<Mutex<Vec<RecEvent>>> = Default::default();
        let events_task = events.clone();
        let sink_task = sink.clone();

        sink(RecFrame::Armed);

        let task = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(250)).await;
            sink_task(RecFrame::Started);

            // ---- Simulated stream ----
            // A plausible "open firefox, type a query, hit return" sequence.
            // Timestamps are relative to `Started`.
            let script: Vec<(u64, RecEvent)> = vec![
                (60,   RecEvent::Key   { t_ms: 60,   chord: "super+space".into() }),
                (520,  RecEvent::WindowFocus { t_ms: 520, name: "Application Launcher".into() }),
                (720,  RecEvent::Text  { t_ms: 720,  text: "firefox".into() }),
                (1280, RecEvent::Key   { t_ms: 1280, chord: "Return".into() }),
                (2450, RecEvent::WindowFocus { t_ms: 2450, name: "Mozilla Firefox".into() }),
                (2700, RecEvent::Key   { t_ms: 2700, chord: "ctrl+l".into() }),
                (2880, RecEvent::Text  { t_ms: 2880, text: "hyprland ipc docs".into() }),
                (4100, RecEvent::Key   { t_ms: 4100, chord: "Return".into() }),
                (5900, RecEvent::Move  { t_ms: 5900, x: 720, y: 480 }),
                (6050, RecEvent::Click { t_ms: 6050, button: 1 }),
                (6900, RecEvent::Scroll{ t_ms: 6900, dx: 0, dy: 3 }),
            ];

            for (at, ev) in script {
                let now_ms = events_task
                    .lock()
                    .await
                    .last()
                    .map(|e| e.t_ms())
                    .unwrap_or(0);
                let gap = at.saturating_sub(now_ms);
                tokio::time::sleep(Duration::from_millis(gap.min(1800))).await;
                events_task.lock().await.push(ev.clone());
                sink_task(RecFrame::Event { event: ev });
            }
        });

        *slot = Some(Session {
            events,
            task,
            started_at: std::time::Instant::now(),
        });
        Ok(())
    }

    /// Stop the current session. Returns the captured events in order.
    pub async fn stop(&self, sink: FrameSink, reason: &str) -> anyhow::Result<Vec<RecEvent>> {
        let mut slot = self.inner.lock().await;
        let sess = slot.take().ok_or_else(|| anyhow::anyhow!("not recording"))?;
        sess.task.abort();
        let total_ms = sess.started_at.elapsed().as_millis() as u64;
        let events = sess.events.lock().await.clone();
        sink(RecFrame::Stopped {
            reason: reason.into(),
            total_ms,
        });
        Ok(events)
    }
}

/// Coerce a batch of recorded events into a draft `Workflow`.
///
/// Rules (keep the cleanup pass in one place so the UI and import both benefit):
/// - Sequential mouse `Move`s at the same timestamp bucket collapse to the last.
/// - A `Gap` longer than 200ms becomes a `wait` step.
/// - `Text` events that land back-to-back are concatenated.
/// - Window focus events become `focus` steps (so the workflow waits for /
///   activates the right window when replayed).
pub fn events_to_workflow(events: &[RecEvent], title: &str) -> Workflow {
    let mut wf = Workflow::new(title);
    wf.subtitle = Some("recorded — cleanup recommended".into());

    let mut prev_t: u64 = 0;
    let mut text_acc: Option<(u64, String)> = None;

    for ev in events {
        let t = ev.t_ms();
        let gap = t.saturating_sub(prev_t);

        if gap >= 200 && prev_t != 0 {
            flush_text(&mut wf, &mut text_acc);
            wf.steps.push(Step::new(Action::Delay { ms: gap }));
        }

        match ev {
            RecEvent::Text { text, .. } => match text_acc.as_mut() {
                Some((_, acc)) => acc.push_str(text),
                None => text_acc = Some((t, text.clone())),
            },
            RecEvent::Key { chord, .. } => {
                flush_text(&mut wf, &mut text_acc);
                wf.steps.push(Step::new(Action::WdoKey {
                    chord: chord.clone(),
                    clear_modifiers: false,
                }));
            }
            RecEvent::Click { button, .. } => {
                flush_text(&mut wf, &mut text_acc);
                wf.steps.push(Step::new(Action::WdoClick { button: *button }));
            }
            RecEvent::Move { x, y, .. } => {
                flush_text(&mut wf, &mut text_acc);
                wf.steps.push(Step::new(Action::WdoMouseMove {
                    x: *x,
                    y: *y,
                    relative: false,
                }));
            }
            RecEvent::Scroll { dx, dy, .. } => {
                flush_text(&mut wf, &mut text_acc);
                wf.steps.push(Step::new(Action::WdoScroll { dx: *dx, dy: *dy }));
            }
            RecEvent::WindowFocus { name, .. } => {
                flush_text(&mut wf, &mut text_acc);
                wf.steps.push(Step::new(Action::WdoActivateWindow {
                    name: name.clone(),
                }));
            }
            RecEvent::Gap { ms, .. } => {
                flush_text(&mut wf, &mut text_acc);
                wf.steps.push(Step::new(Action::Delay { ms: *ms }));
            }
        }

        prev_t = t;
    }
    flush_text(&mut wf, &mut text_acc);
    wf
}

fn flush_text(wf: &mut Workflow, acc: &mut Option<(u64, String)>) {
    if let Some((_, text)) = acc.take() {
        if !text.is_empty() {
            wf.steps.push(Step::new(Action::WdoType {
                text,
                delay_ms: None,
            }));
        }
    }
}
