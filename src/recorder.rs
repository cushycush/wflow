//! Record mode backend.
//!
//! Two backends:
//!
//! * **Portal (default)** — opens an xdg-desktop-portal `RemoteDesktop`
//!   session, attaches to the EIS socket via `connect_to_eis`, and streams
//!   real pointer / keyboard / scroll events from the compositor through
//!   `reis` in receiver mode. The user sees the portal's consent dialog;
//!   capture is unconditional until `stop`.
//!
//! * **Simulated** — a deterministic script; used as a dev fallback and
//!   taken automatically when the portal path errors out. Force it with
//!   `WFLOW_SIM_RECORDER=1` for UI iteration off-portal.
//!
//! A session's events stream in through a `FrameSink` the bridge supplies
//! so Qt can repaint on each frame.

use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Context as _, Result};
use ashpd::desktop::remote_desktop::{DeviceType, RemoteDesktop, SelectDevicesOptions};
use futures_util::StreamExt;
use reis::ei;
use reis::event::{DeviceCapability, EiEvent};
use serde::{Deserialize, Serialize};
use tokio::sync::{oneshot, Mutex};
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
    task: Option<JoinHandle<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
    stop_tx: Option<oneshot::Sender<()>>,
    started_at: std::time::Instant,
}

impl Recorder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Start a new recording session. Calls `sink` with each `RecFrame`.
    ///
    /// Goes through the RemoteDesktop portal by default. The simulated
    /// backend is opt-in via `WFLOW_SIM_RECORDER=1` (used during UI
    /// iteration so we don't have to click through the portal consent
    /// dialog every time).
    ///
    /// If the portal path fails, the error propagates to the caller.
    /// We deliberately do NOT silently fall back to simulated, because
    /// fake events that look real are worse than a clear error: the
    /// user thinks Record works and then their saved workflow does
    /// nothing on replay. The bridge surfaces the error string in the
    /// UI so the user can see exactly what went wrong (most often:
    /// their compositor's portal doesn't implement RemoteDesktop, or
    /// they cancelled the consent dialog).
    pub async fn start(&self, sink: FrameSink) -> Result<()> {
        {
            let slot = self.inner.lock().await;
            if slot.is_some() {
                anyhow::bail!("a recording session is already in progress");
            }
        }

        let force_sim = std::env::var("WFLOW_SIM_RECORDER").ok().as_deref() == Some("1");
        if force_sim {
            tracing::info!("recorder: WFLOW_SIM_RECORDER=1 — using simulated backend");
            return self.start_simulated(sink).await;
        }

        self.start_portal(sink).await.map_err(|e| {
            tracing::warn!(error = %format!("{e:#}"), "recorder: portal backend failed");
            e.context(
                "Record needs xdg-desktop-portal with the RemoteDesktop interface. \
                 Plasma 6 and GNOME 46+ ship it; xdg-desktop-portal-hyprland and \
                 xdg-desktop-portal-wlr currently do not. Set WFLOW_SIM_RECORDER=1 \
                 to test the UI with simulated events.",
            )
        })
    }

    /// Stop the current session. Returns the captured events in order.
    pub async fn stop(&self, sink: FrameSink, reason: &str) -> Result<Vec<RecEvent>> {
        let mut slot = self.inner.lock().await;
        let mut sess = slot
            .take()
            .ok_or_else(|| anyhow!("not recording"))?;
        if let Some(tx) = sess.stop_tx.take() {
            let _ = tx.send(());
        }
        if let Some(t) = sess.task.take() {
            t.abort();
        }
        // Portal backend lives on a dedicated OS thread. Give it a moment to
        // tear down the portal session cleanly before we stop waiting on it.
        if let Some(th) = sess.thread.take() {
            let _ = std::thread::Builder::new()
                .name("wflow-rec-wait".into())
                .spawn(move || {
                    let _ = th.join();
                });
        }
        let total_ms = sess.started_at.elapsed().as_millis() as u64;
        let events = sess.events.lock().await.clone();
        sink(RecFrame::Stopped {
            reason: reason.into(),
            total_ms,
        });
        Ok(events)
    }

    // ----------------------- Backends ------------------------------

    async fn start_simulated(&self, sink: FrameSink) -> Result<()> {
        let events: Arc<Mutex<Vec<RecEvent>>> = Default::default();
        let events_task = events.clone();
        let sink_task = sink.clone();

        sink(RecFrame::Armed);

        let task = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(250)).await;
            sink_task(RecFrame::Started);

            // A plausible "open firefox, type a query, hit return" sequence.
            // (Simulated backend only — portal pumps real events.)
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

        let mut slot = self.inner.lock().await;
        *slot = Some(Session {
            events,
            task: Some(task),
            thread: None,
            stop_tx: None,
            started_at: std::time::Instant::now(),
        });
        Ok(())
    }

    async fn start_portal(&self, sink: FrameSink) -> Result<()> {
        // 1) Open the RemoteDesktop portal, create a session, ask for Keyboard
        //    + Pointer, and Start — which pops the consent dialog. All of
        //    this part is Send-safe; the EIS stream isn't, so once we have
        //    the FD we hand everything off to a dedicated OS thread with its
        //    own single-threaded tokio runtime.
        let rd = RemoteDesktop::new()
            .await
            .context("open RemoteDesktop portal proxy")?;
        let session = rd
            .create_session(Default::default())
            .await
            .context("create RemoteDesktop session")?;
        rd.select_devices(
            &session,
            SelectDevicesOptions::default()
                .set_devices(DeviceType::Keyboard | DeviceType::Pointer),
        )
        .await
        .context("select Keyboard+Pointer devices")?;
        rd.start(&session, None, Default::default())
            .await
            .context("start RemoteDesktop session")?
            .response()
            .context("portal dialog denied or failed")?;

        // 2) Grab the EIS file descriptor. `rd` and `session` must outlive
        //    the EIS connection, so we move them into the pump thread below.
        let fd = rd
            .connect_to_eis(&session, Default::default())
            .await
            .context("ConnectToEIS (needs RemoteDesktop v2)")?;
        let stream = UnixStream::from(fd);
        let context = ei::Context::new(stream).context("wrap EIS fd in ei::Context")?;

        // 3) Dedicated OS thread owns the (non-Send) EI stream and drives a
        //    current-thread tokio runtime. The parent runtime stays
        //    multi-threaded for the rest of the app.
        let events: Arc<Mutex<Vec<RecEvent>>> = Default::default();
        let events_thread = events.clone();
        let sink_thread = sink.clone();
        let (stop_tx, stop_rx) = oneshot::channel::<()>();

        sink(RecFrame::Armed);

        let thread = std::thread::Builder::new()
            .name("wflow-rec-eis".into())
            .spawn(move || {
                let rt = match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(r) => r,
                    Err(e) => {
                        tracing::warn!(error = %e, "recorder: failed to build EIS runtime");
                        return;
                    }
                };
                rt.block_on(run_portal_pump(
                    rd,
                    session,
                    context,
                    stop_rx,
                    events_thread,
                    sink_thread,
                ));
            })
            .context("spawn EIS pump thread")?;

        let mut slot = self.inner.lock().await;
        *slot = Some(Session {
            events,
            task: None,
            thread: Some(thread),
            stop_tx: Some(stop_tx),
            started_at: std::time::Instant::now(),
        });
        Ok(())
    }
}

// ------------------------------- Portal pump -------------------------------

/// The EIS event loop. Runs on a current-thread tokio runtime owned by the
/// dedicated pump thread — reis's event stream isn't `Send`, so it can't
/// live on the multi-thread runtime. Tears the portal session down when the
/// stop channel fires or the compositor closes the connection.
async fn run_portal_pump(
    _rd: RemoteDesktop,
    _session: ashpd::desktop::Session<RemoteDesktop>,
    context: ei::Context,
    stop_rx: oneshot::Receiver<()>,
    events: Arc<Mutex<Vec<RecEvent>>>,
    sink: FrameSink,
) {
    let handshake = context
        .handshake_tokio("wflow-recorder", ei::handshake::ContextType::Receiver)
        .await;
    let (_connection, mut stream) = match handshake {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!(error = %format!("{e:#}"), "EIS handshake failed");
            return;
        }
    };

    sink(RecFrame::Started);
    let start = std::time::Instant::now();
    let mut last_x: i32 = i32::MIN;
    let mut last_y: i32 = i32::MIN;
    let mut rel_x: f32 = 0.0;
    let mut rel_y: f32 = 0.0;
    let mut mods: u32 = 0;

    tokio::pin!(stop_rx);
    loop {
        tokio::select! {
            _ = &mut stop_rx => {
                tracing::debug!("recorder: stop requested");
                break;
            }
            maybe_event = stream.next() => {
                let Some(event) = maybe_event else { break };
                let event = match event {
                    Ok(e) => e,
                    Err(e) => {
                        tracing::warn!(error = %format!("{e:?}"), "EIS stream error");
                        break;
                    }
                };
                if let EiEvent::SeatAdded(evt) = &event {
                    evt.seat.bind_capabilities(
                        DeviceCapability::Pointer
                            | DeviceCapability::PointerAbsolute
                            | DeviceCapability::Keyboard
                            | DeviceCapability::Button
                            | DeviceCapability::Scroll,
                    );
                    let _ = context.flush();
                }

                if let Some(rec_event) = event_to_rec(
                    &event,
                    start,
                    &mut last_x,
                    &mut last_y,
                    &mut rel_x,
                    &mut rel_y,
                    &mut mods,
                ) {
                    events.lock().await.push(rec_event.clone());
                    sink(RecFrame::Event { event: rec_event });
                }
            }
        }
    }
}

// ------------------------------- Event mapping ------------------------------

/// Convert an EIS event into a `RecEvent` if it's one we care to capture.
/// Pure function so the session loop above stays readable.
fn event_to_rec(
    event: &EiEvent,
    start: std::time::Instant,
    last_x: &mut i32,
    last_y: &mut i32,
    rel_x: &mut f32,
    rel_y: &mut f32,
    mods: &mut u32,
) -> Option<RecEvent> {
    let t_ms = start.elapsed().as_millis() as u64;
    match event {
        EiEvent::Button(evt) => {
            // Only record the press (release is implicit in replay via
            // wdotool click). Map Linux input-event-codes to wdotool buttons.
            if evt.state != reis::ei::button::ButtonState::Press {
                return None;
            }
            let button = match evt.button {
                0x110 /* BTN_LEFT */   => 1,
                0x112 /* BTN_MIDDLE */ => 2,
                0x111 /* BTN_RIGHT */  => 3,
                0x113 /* BTN_SIDE */   => 8,
                0x114 /* BTN_EXTRA */  => 9,
                _ => return None,
            };
            Some(RecEvent::Click { t_ms, button })
        }
        EiEvent::PointerMotionAbsolute(evt) => {
            let x = evt.dx_absolute as i32;
            let y = evt.dy_absolute as i32;
            let moved = *last_x == i32::MIN
                || (x - *last_x).abs() >= 4
                || (y - *last_y).abs() >= 4;
            if !moved {
                return None;
            }
            *last_x = x;
            *last_y = y;
            Some(RecEvent::Move { t_ms, x, y })
        }
        EiEvent::PointerMotion(evt) => {
            // Accumulate relative motion; emit when the running total crosses
            // ~4px on either axis so we don't flood the log. Absolute x/y
            // isn't recoverable from deltas alone, so we leave x=-1,y=-1 as
            // a signal that the step will need manual tweaking on replay.
            *rel_x += evt.dx;
            *rel_y += evt.dy;
            if rel_x.abs() < 4.0 && rel_y.abs() < 4.0 {
                return None;
            }
            let dx = *rel_x as i32;
            let dy = *rel_y as i32;
            *rel_x = 0.0;
            *rel_y = 0.0;
            Some(RecEvent::Move { t_ms, x: dx, y: dy })
        }
        EiEvent::ScrollDiscrete(evt) => Some(RecEvent::Scroll {
            t_ms,
            dx: evt.discrete_dx,
            dy: evt.discrete_dy,
        }),
        EiEvent::ScrollDelta(evt) => Some(RecEvent::Scroll {
            t_ms,
            dx: evt.dx as i32,
            dy: evt.dy as i32,
        }),
        EiEvent::KeyboardModifiers(evt) => {
            *mods = evt.depressed | evt.latched | evt.locked;
            None
        }
        EiEvent::KeyboardKey(evt) => {
            if evt.state != reis::ei::keyboard::KeyState::Press {
                return None;
            }
            let chord = keycode_to_chord(evt.key, *mods)?;
            Some(RecEvent::Key { t_ms, chord })
        }
        _ => None,
    }
}

/// Build a wdotool-ish chord string from a Linux keycode + modifier bitmask.
/// This is deliberately minimal — a proper mapping needs xkbcommon and the
/// keymap the compositor ships. Enough for navigation-style recordings
/// (modifier-heavy chords; plain letter keys fall through as the raw code,
/// which the user can fix up in the editor).
fn keycode_to_chord(key: u32, mods: u32) -> Option<String> {
    // xkb modifier masks — real indices come from the keymap, but GNOME's
    // portal consistently maps the canonical ones in these slots.
    const MOD_SHIFT: u32 = 1 << 0;
    const MOD_CTRL: u32 = 1 << 2;
    const MOD_ALT: u32 = 1 << 3;
    const MOD_SUPER: u32 = 1 << 6;

    let mut parts: Vec<&str> = Vec::new();
    if mods & MOD_CTRL  != 0 { parts.push("ctrl"); }
    if mods & MOD_ALT   != 0 { parts.push("alt"); }
    if mods & MOD_SHIFT != 0 { parts.push("shift"); }
    if mods & MOD_SUPER != 0 { parts.push("super"); }

    // Minimal keycode → name table. Linux input-event-codes (`KEY_*`).
    // Anything not in this table round-trips as `keyNN` so the user has
    // something to edit — better than dropping the event.
    let name = match key {
        1   => "Escape",
        14  => "BackSpace",
        15  => "Tab",
        28  => "Return",
        57  => "space",
        103 => "Up",
        108 => "Down",
        105 => "Left",
        106 => "Right",
        102 => "Home",
        107 => "End",
        104 => "Prior",     // Page Up
        109 => "Next",      // Page Down
        111 => "Delete",
        59..=68 => {
            // Function keys F1..F10
            static FK: &[&str] = &["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10"];
            FK[(key - 59) as usize]
        }
        87 => "F11",
        88 => "F12",
        _ => {
            let fallback = format!("key{key}");
            if parts.is_empty() {
                return Some(fallback);
            }
            parts.push(fallback.as_str());
            return Some(parts.join("+"));
        }
    };
    parts.push(name);
    Some(parts.join("+"))
}

// --------------------------- Events → Workflow ------------------------------

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
