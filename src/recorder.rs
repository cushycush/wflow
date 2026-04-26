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
    /// Internally-generated stop request (e.g. user pressed Esc).
    /// The bridge handles this by calling `Recorder::stop` from a
    /// fresh task — saves the user from having to switch back to
    /// wflow and click the Stop button (which itself gets recorded
    /// as a stray click otherwise).
    StopRequested,
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
    /// Backend priority:
    /// 1. **Portal.** `org.freedesktop.portal.RemoteDesktop` + libei
    ///    receiver. The "right" path: explicit consent dialog, no
    ///    /dev/input/* permissions needed. Plasma 6 and GNOME 46+
    ///    ship the interface; xdg-desktop-portal-hyprland and
    ///    xdg-desktop-portal-wlr don't (yet).
    /// 2. **Evdev.** Reads /dev/input/event* directly. Works on any
    ///    compositor as long as the user is in the `input` group.
    ///    No per-session consent prompt — the input group membership
    ///    is the consent.
    /// 3. **Simulated.** Opt-in via `WFLOW_SIM_RECORDER=1`. UI
    ///    iteration only.
    ///
    /// If portal AND evdev both fail we propagate a combined error
    /// so the user sees both reasons (typically: "portal interface
    /// missing" + "permission denied on /dev/input/event*"). We
    /// deliberately do NOT fall through to simulated on failure;
    /// fake events that look real are worse than a clear error.
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

        let portal_err = match self.start_portal(sink.clone()).await {
            Ok(()) => return Ok(()),
            Err(e) => {
                tracing::info!(error = %format!("{e:#}"), "recorder: portal backend unavailable, trying evdev");
                e
            }
        };

        match self.start_evdev(sink).await {
            Ok(()) => Ok(()),
            Err(evdev_err) => {
                tracing::warn!(error = %format!("{evdev_err:#}"), "recorder: evdev backend failed too");
                Err(anyhow!(
                    "Record can't start.\n\nPortal backend: {portal_err:#}\n\nEvdev backend: {evdev_err:#}\n\n\
                     Pick one of these to fix it:\n  \
                     • On Plasma 6 or GNOME 46+, install / restart xdg-desktop-portal\n  \
                     • On Hyprland or Sway, add yourself to the `input` group: \
                     `sudo usermod -aG input $USER`, log out and back in"
                ))
            }
        }
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
        // Trim in PLACE on the Mutex'd buffer. The bridge's
        // finalize() reads back through the same Arc<Mutex>, so a
        // local clone-and-trim wouldn't persist past this function.
        let events = {
            let mut e = sess.events.lock().await;
            trim_stop_tail(&mut e, total_ms);
            e.clone()
        };
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

    /// Open every readable /dev/input/event* device that emits keys
    /// or pointer events, and merge their streams into the same
    /// per-recording event log. No portal, no consent dialog — the
    /// `input` group membership is the consent. Used as a fallback
    /// on compositors whose portal doesn't expose RemoteDesktop.
    async fn start_evdev(&self, sink: FrameSink) -> Result<()> {
        use evdev::EventType;
        use std::sync::atomic::{AtomicU32, AtomicU64};
        use tokio::task::JoinSet;

        // Enumerate at start time (no hot-plug). Filter to devices
        // that actually emit useful event types — skip power buttons,
        // lid switches, gpio dummies, etc.
        let mut devices: Vec<(std::path::PathBuf, evdev::Device)> = Vec::new();
        for (path, dev) in evdev::enumerate() {
            let supports_keys = dev.supported_keys().is_some();
            let supports_rel = dev.supported_relative_axes().is_some();
            if supports_keys || supports_rel {
                devices.push((path, dev));
            }
        }

        if devices.is_empty() {
            anyhow::bail!(
                "no readable input devices at /dev/input/event* — \
                 check that you're in the `input` group \
                 (`groups | grep input`); if not, run \
                 `sudo usermod -aG input $USER` and log out/back in"
            );
        }

        let events: Arc<Mutex<Vec<RecEvent>>> = Default::default();
        let started_at = std::time::Instant::now();
        // Shared modifier bitmask across all devices, in the same xkb
        // bit positions keycode_to_chord expects.
        let mods = Arc::new(AtomicU32::new(0));
        // Global mouse-motion throttle. evdev gives us raw REL_X/REL_Y
        // events at the device's full polling rate (1000Hz on a gaming
        // mouse), and the libei portal isn't here to coalesce. Without
        // a throttle the sink/Qt thread saturates and the GUI freezes
        // while keyboard tasks starve waiting on the events Mutex.
        // Default 1000ms feels right for a workflow recording (the
        // Move events are sentinels not high-fidelity traces); tune
        // via WFLOW_REC_MOVE_INTERVAL_MS if a real workflow needs
        // finer resolution.
        let last_move_ms = Arc::new(AtomicU64::new(0));
        let min_move_interval_ms: u64 = std::env::var("WFLOW_REC_MOVE_INTERVAL_MS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(1000);

        sink(RecFrame::Armed);
        sink(RecFrame::Started);

        // One tokio task per device; the coordinator owns the JoinSet
        // so dropping the coordinator on stop() abort tears them all
        // down.
        let mut joinset = JoinSet::new();
        for (path, dev) in devices {
            let mut stream = match dev.into_event_stream() {
                Ok(s) => s,
                Err(e) => {
                    tracing::warn!(?path, ?e, "evdev: stream open failed; skipping device");
                    continue;
                }
            };
            let events_dev = events.clone();
            let sink_dev = sink.clone();
            let mods_dev = mods.clone();
            let last_move_dev = last_move_ms.clone();
            joinset.spawn(async move {
                // Per-device accumulators for relative pointer motion.
                let mut rel_x: i32 = 0;
                let mut rel_y: i32 = 0;
                loop {
                    let ev = match stream.next_event().await {
                        Ok(e) => e,
                        Err(_) => break,
                    };
                    // Super+Esc is the global stop hotkey. Don't
                    // record the press; signal the bridge to stop.
                    // Plain Esc stays as a recordable keystroke so
                    // workflows that close dialogs / cancel inputs
                    // still capture cleanly. Super was picked because
                    // it's almost never bound on its own and pairs
                    // with WM hotkeys the user already trains on.
                    if let evdev::EventSummary::Key(_, code, value) = ev.destructure() {
                        if code == evdev::KeyCode::KEY_ESC && value == 1 {
                            const MOD_SUPER: u32 = 1 << 6;
                            let m = mods_dev.load(std::sync::atomic::Ordering::Relaxed);
                            if m & MOD_SUPER != 0 {
                                sink_dev(RecFrame::StopRequested);
                                break;
                            }
                        }
                    }
                    let t_ms = started_at.elapsed().as_millis() as u64;
                    if let Some(rec) = evdev_to_rec(
                        &ev,
                        t_ms,
                        &mods_dev,
                        &mut rel_x,
                        &mut rel_y,
                        &last_move_dev,
                        min_move_interval_ms,
                    ) {
                        events_dev.lock().await.push(rec.clone());
                        sink_dev(RecFrame::Event { event: rec });
                    }
                    // Skip SYN_REPORT and other framing events without
                    // accidentally matching them above.
                    if ev.event_type() == EventType::SYNCHRONIZATION {
                        continue;
                    }
                }
            });
        }

        // Compositor event subscriber, if we recognize one. Runs in
        // the same JoinSet so it stops with the rest of the recording.
        // Today: Hyprland only. Sway / KWin / Mutter equivalents go
        // here as users hit them.
        if let Some(path) = hyprland_socket_path() {
            let events_h = events.clone();
            let sink_h = sink.clone();
            joinset.spawn(async move {
                if let Err(e) = hyprland_subscribe(&path, started_at, events_h, sink_h).await {
                    tracing::warn!(error = %format!("{e:#}"), "hyprland subscriber exited");
                }
            });
        }

        // Coordinator: just keeps the JoinSet alive. On stop(), the
        // outer code aborts this handle, which drops the JoinSet,
        // which aborts every device task.
        let coordinator = tokio::spawn(async move {
            while joinset.join_next().await.is_some() {}
        });

        let mut slot = self.inner.lock().await;
        *slot = Some(Session {
            events,
            task: Some(coordinator),
            thread: None,
            stop_tx: None,
            started_at,
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

    // Linux input-event-codes (`KEY_*`) → wdotool/xdotool keysym name.
    // The table covers the US-en QWERTY layout; non-US layouts will see
    // some letters map to the wrong keysym, which the user can fix in
    // the editor. A proper layout-aware mapping needs xkbcommon and
    // the compositor's keymap; that's a future polish.
    //
    // Anything not in the table falls through to `keyNN` so events are
    // never silently dropped.
    let name = match key {
        // Editing / navigation
        1   => "Escape",
        14  => "BackSpace",
        15  => "Tab",
        28  => "Return",
        57  => "space",
        96  => "Return",   // KP_Enter — keypad Enter
        103 => "Up",
        108 => "Down",
        105 => "Left",
        106 => "Right",
        102 => "Home",
        107 => "End",
        104 => "Prior",     // Page Up
        109 => "Next",      // Page Down
        110 => "Insert",
        111 => "Delete",

        // Function keys
        59..=68 => {
            static FK: &[&str] = &["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10"];
            FK[(key - 59) as usize]
        }
        87 => "F11",
        88 => "F12",

        // Top number row (1234567890 -=)
        2   => "1",  3  => "2",  4  => "3",  5  => "4",  6  => "5",
        7   => "6",  8  => "7",  9  => "8", 10  => "9", 11  => "0",
        12  => "minus",
        13  => "equal",

        // Letter rows (QWERTY)
        16 => "q", 17 => "w", 18 => "e", 19 => "r", 20 => "t",
        21 => "y", 22 => "u", 23 => "i", 24 => "o", 25 => "p",
        26 => "bracketleft",
        27 => "bracketright",
        43 => "backslash",
        30 => "a", 31 => "s", 32 => "d", 33 => "f", 34 => "g",
        35 => "h", 36 => "j", 37 => "k", 38 => "l",
        39 => "semicolon",
        40 => "apostrophe",
        41 => "grave",
        44 => "z", 45 => "x", 46 => "c", 47 => "v", 48 => "b",
        49 => "n", 50 => "m",
        51 => "comma",
        52 => "period",
        53 => "slash",

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

/// Convert a single evdev `InputEvent` into a `RecEvent`. Updates
/// `mods` and the per-device `rel_x`/`rel_y` accumulators in place
/// for events that don't directly produce a `RecEvent` (modifier
/// keys, sub-threshold pointer motion, SYN_REPORT framing).
///
/// Mouse motion is time-throttled via `last_move_ms` /
/// `min_move_interval_ms`. Below the interval, REL_X/REL_Y events
/// accumulate into `rel_x`/`rel_y` and produce no `RecEvent`. At or
/// above the interval, the accumulator flushes as a single Move and
/// the throttle clock resets.
fn evdev_to_rec(
    ev: &evdev::InputEvent,
    t_ms: u64,
    mods: &std::sync::atomic::AtomicU32,
    rel_x: &mut i32,
    rel_y: &mut i32,
    last_move_ms: &std::sync::atomic::AtomicU64,
    min_move_interval_ms: u64,
) -> Option<RecEvent> {
    use evdev::{EventSummary, KeyCode, RelativeAxisCode};
    use std::sync::atomic::Ordering;

    // xkb modifier bit positions, matching keycode_to_chord.
    const MOD_SHIFT: u32 = 1 << 0;
    const MOD_CTRL: u32 = 1 << 2;
    const MOD_ALT: u32 = 1 << 3;
    const MOD_SUPER: u32 = 1 << 6;

    fn modifier_bit(k: KeyCode) -> Option<u32> {
        Some(match k {
            KeyCode::KEY_LEFTSHIFT | KeyCode::KEY_RIGHTSHIFT => MOD_SHIFT,
            KeyCode::KEY_LEFTCTRL | KeyCode::KEY_RIGHTCTRL => MOD_CTRL,
            KeyCode::KEY_LEFTALT | KeyCode::KEY_RIGHTALT => MOD_ALT,
            KeyCode::KEY_LEFTMETA | KeyCode::KEY_RIGHTMETA => MOD_SUPER,
            _ => return None,
        })
    }

    match ev.destructure() {
        EventSummary::Key(_, code, value) => {
            // value: 0 = release, 1 = press, 2 = repeat. Only emit
            // on initial press; repeats and releases are discarded
            // for plain keys (modifiers track release for chord
            // bookkeeping below).
            if let Some(bit) = modifier_bit(code) {
                let m = mods.load(Ordering::Relaxed);
                let new = match value {
                    0 => m & !bit,
                    1 | 2 => m | bit,
                    _ => m,
                };
                mods.store(new, Ordering::Relaxed);
                return None;
            }

            // Mouse buttons land here too — KEY_* and BTN_* share
            // the keycode space.
            let button = match code {
                KeyCode::BTN_LEFT => Some(1),
                KeyCode::BTN_MIDDLE => Some(2),
                KeyCode::BTN_RIGHT => Some(3),
                KeyCode::BTN_SIDE => Some(8),
                KeyCode::BTN_EXTRA => Some(9),
                _ => None,
            };
            if let Some(btn) = button {
                if value == 1 {
                    return Some(RecEvent::Click { t_ms, button: btn });
                }
                return None;
            }

            // Plain key: emit on press only.
            if value != 1 {
                return None;
            }
            let chord = keycode_to_chord(code.0 as u32, mods.load(Ordering::Relaxed))?;
            Some(RecEvent::Key { t_ms, chord })
        }
        EventSummary::RelativeAxis(_, axis, value) => {
            match axis {
                RelativeAxisCode::REL_X => {
                    *rel_x = rel_x.saturating_add(value);
                }
                RelativeAxisCode::REL_Y => {
                    *rel_y = rel_y.saturating_add(value);
                }
                RelativeAxisCode::REL_WHEEL | RelativeAxisCode::REL_WHEEL_HI_RES => {
                    return Some(RecEvent::Scroll { t_ms, dx: 0, dy: value });
                }
                RelativeAxisCode::REL_HWHEEL | RelativeAxisCode::REL_HWHEEL_HI_RES => {
                    return Some(RecEvent::Scroll { t_ms, dx: value, dy: 0 });
                }
                _ => return None,
            }
            // Time-throttle Move emission. Without this, every mouse
            // tick (1000Hz on a gaming mouse) tries to round-trip
            // through the Qt thread queue and the keyboard tasks
            // starve waiting on the shared events Mutex. Default
            // interval is 1000ms — Move events are sentinels for
            // "user moved here," not high-fidelity traces, so a slow
            // cadence is fine.
            let last = last_move_ms.load(std::sync::atomic::Ordering::Relaxed);
            if t_ms.saturating_sub(last) < min_move_interval_ms {
                // Keep accumulating into rel_x/rel_y so the eventual
                // emit reflects the full motion since the last
                // sample.
                return None;
            }
            last_move_ms.store(t_ms, std::sync::atomic::Ordering::Relaxed);
            let dx = std::mem::take(rel_x);
            let dy = std::mem::take(rel_y);
            // Absolute screen position isn't recoverable from
            // relative deltas; the synthetic Move carries the
            // accumulated dx/dy as a hint, the user fixes up
            // coordinates in the editor on replay.
            Some(RecEvent::Move {
                t_ms,
                x: dx,
                y: dy,
            })
        }
        _ => None,
    }
}

// --------------------------- Trim trailing stop input -----------------------

/// The user always stops a recording by switching to wflow's own
/// window and clicking the Stop button. That switch lands as a
/// `WindowFocus { name: "wflow" }` event from the Hyprland
/// subscriber, followed by the mouse-to-button motion + click
/// from the evdev backend. Any user-meaningful workflow won't
/// have wflow focused mid-recording (because if it did, you
/// couldn't be operating the target app), so the rule is:
/// truncate at the LAST `focus wflow` event.
///
/// The earlier 300ms time-window trim missed the natural-paced
/// case (user takes ~800ms to alt-tab and click), so move to the
/// semantic signal instead. `total_ms` stays in the signature
/// for future heuristics.
fn trim_stop_tail(events: &mut Vec<RecEvent>, _total_ms: u64) {
    let mut cut: Option<usize> = None;
    for (i, ev) in events.iter().enumerate() {
        if let RecEvent::WindowFocus { name, .. } = ev {
            if name.eq_ignore_ascii_case("wflow") {
                cut = Some(i);
                // Keep iterating — we want the LAST switch to
                // wflow, not the first.
            }
        }
    }
    if let Some(i) = cut {
        events.truncate(i);
    }
}

#[cfg(test)]
mod trim_tests {
    use super::*;

    #[test]
    fn truncates_at_focus_wflow_and_drops_everything_after() {
        let mut events = vec![
            RecEvent::Key { t_ms: 800, chord: "a".into() },
            RecEvent::WindowFocus { t_ms: 1500, name: "wflow".into() },
            RecEvent::Move { t_ms: 1700, x: 5, y: 5 },
            RecEvent::Click { t_ms: 1900, button: 1 },
        ];
        trim_stop_tail(&mut events, 2000);
        assert_eq!(events.len(), 1);
        assert!(matches!(events[0], RecEvent::Key { .. }));
    }

    #[test]
    fn matches_wflow_focus_case_insensitively() {
        let mut events = vec![
            RecEvent::Key { t_ms: 100, chord: "a".into() },
            RecEvent::WindowFocus { t_ms: 200, name: "Wflow".into() },
            RecEvent::Click { t_ms: 300, button: 1 },
        ];
        trim_stop_tail(&mut events, 400);
        assert_eq!(events.len(), 1);
    }

    #[test]
    fn cuts_at_last_wflow_focus_not_first() {
        // Earlier glance at wflow (mid-recording) shouldn't truncate
        // the whole capture — only the FINAL switch counts.
        let mut events = vec![
            RecEvent::WindowFocus { t_ms: 100, name: "wflow".into() },
            RecEvent::Key { t_ms: 200, chord: "a".into() },
            RecEvent::WindowFocus { t_ms: 800, name: "firefox".into() },
            RecEvent::Key { t_ms: 900, chord: "b".into() },
            RecEvent::WindowFocus { t_ms: 1500, name: "wflow".into() },
            RecEvent::Click { t_ms: 1600, button: 1 },
        ];
        trim_stop_tail(&mut events, 1700);
        // Truncated at the LAST wflow focus (index 4): keeps
        // indices 0..4, dropping the wflow-focus and the click.
        assert_eq!(events.len(), 4);
        match &events[3] {
            RecEvent::Key { chord, .. } => assert_eq!(chord, "b"),
            _ => panic!("expected last surviving event to be Key 'b'"),
        }
    }

    #[test]
    fn no_wflow_focus_means_no_trim() {
        let mut events = vec![
            RecEvent::Key { t_ms: 100, chord: "a".into() },
            RecEvent::Click { t_ms: 200, button: 1 },
        ];
        trim_stop_tail(&mut events, 300);
        assert_eq!(events.len(), 2);
    }
}

// --------------------------- Compositor events ------------------------------

/// Hyprland's IPC event socket. Returns None when not running under
/// Hyprland (env var unset) or when the expected socket file is
/// missing for whatever reason.
fn hyprland_socket_path() -> Option<std::path::PathBuf> {
    let his = std::env::var("HYPRLAND_INSTANCE_SIGNATURE").ok()?;
    let runtime = std::env::var("XDG_RUNTIME_DIR").ok()?;
    let path = std::path::PathBuf::from(runtime)
        .join("hypr")
        .join(&his)
        .join(".socket2.sock");
    if !path.exists() {
        return None;
    }
    Some(path)
}

/// Subscribe to Hyprland's `.socket2.sock` event stream and convert
/// the events we care about into `RecEvent`s pushed to the same
/// recording the input backends are writing to. Window focus changes
/// and new windows opening become `WindowFocus` events; everything
/// else (workspace switches, monitor add/remove, layouts) is dropped.
///
/// Dedupes consecutive WindowFocus events by class so alt-tabbing
/// between two windows doesn't flood the recording with redundant
/// frames.
async fn hyprland_subscribe(
    path: &std::path::Path,
    started_at: std::time::Instant,
    events: Arc<Mutex<Vec<RecEvent>>>,
    sink: FrameSink,
) -> anyhow::Result<()> {
    use tokio::io::{AsyncBufReadExt, BufReader};
    use tokio::net::UnixStream;
    let stream = UnixStream::connect(path)
        .await
        .with_context(|| format!("connect Hyprland event socket {}", path.display()))?;
    let reader = BufReader::new(stream);
    let mut lines = reader.lines();
    let mut last_class = String::new();
    while let Some(line) = lines.next_line().await? {
        // Format: "eventname>>data1,data2,..."
        let Some((name, data)) = line.split_once(">>") else { continue };
        let t_ms = started_at.elapsed().as_millis() as u64;
        let class = match name {
            // activewindow data: "class,title". Title shifts as the
            // app updates its window title (kitty showing nvim's
            // current file, etc.); class is what the user typed.
            "activewindow" => data.split_once(',').map(|(c, _t)| c.to_string()),
            // openwindow data: "address,workspace,class,title".
            "openwindow" => data.splitn(4, ',').nth(2).map(|s| s.to_string()),
            _ => None,
        };
        let Some(class) = class else { continue };
        if class.is_empty() || class == last_class {
            continue;
        }
        last_class = class.clone();
        let rec = RecEvent::WindowFocus { t_ms, name: class };
        events.lock().await.push(rec.clone());
        sink(RecFrame::Event { event: rec });
    }
    Ok(())
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
                // A bare printable key ("h", "space", "comma", …)
                // accumulates into the text buffer so a string like
                // "hello world" coalesces into a single `type` step
                // instead of 11 separate WdoKey steps that fire
                // faster than the target app can process. Real
                // chords (modifier-bearing, function keys, etc.)
                // flush the text and emit a `key` step.
                if let Some(ch) = chord_as_typed_char(chord) {
                    match text_acc.as_mut() {
                        Some((_, acc)) => acc.push_str(&ch),
                        None => text_acc = Some((t, ch)),
                    }
                } else {
                    flush_text(&mut wf, &mut text_acc);
                    wf.steps.push(Step::new(Action::WdoKey {
                        chord: chord.clone(),
                        clear_modifiers: false,
                    }));
                }
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
                // Compositor activate-window requests are best-effort
                // and asynchronous on most Wayland compositors. Without
                // a small grace period, the next key/click in the
                // recording fires before focus has actually moved, so
                // the input lands in whatever was previously focused
                // (typically wflow itself if the user just clicked
                // Run). 150ms is enough on Hyprland and KWin in
                // practice; the user can shorten the inserted Delay
                // step if their compositor is faster.
                wf.steps.push(Step::new(Action::Delay { ms: 150 }));
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

/// Convert a wdotool keysym chord into the literal string a user
/// would have typed to produce it. Used to coalesce sequential
/// printable Key events back into a single `type` action on
/// playback. Returns None for chords that don't have a literal
/// typed form (modifier-bearing chords, function keys, navigation).
fn chord_as_typed_char(chord: &str) -> Option<String> {
    if chord.contains('+') {
        return None;
    }
    let s = match chord {
        "space" => " ",
        "comma" => ",",
        "period" => ".",
        "slash" => "/",
        "minus" => "-",
        "equal" => "=",
        "bracketleft" => "[",
        "bracketright" => "]",
        "backslash" => "\\",
        "semicolon" => ";",
        "apostrophe" => "'",
        "grave" => "`",
        c if c.len() == 1 && c.chars().next().is_some_and(|ch| ch.is_ascii_alphanumeric()) => c,
        _ => return None,
    };
    Some(s.to_string())
}

#[cfg(test)]
mod coalesce_tests {
    use super::*;
    use crate::actions::Action;

    fn keys(chords: &[(u64, &str)]) -> Vec<RecEvent> {
        chords
            .iter()
            .map(|(t, c)| RecEvent::Key {
                t_ms: *t,
                chord: (*c).into(),
            })
            .collect()
    }

    #[test]
    fn coalesces_letters_into_one_type_action() {
        let evs = keys(&[
            (100, "h"), (110, "e"), (120, "l"), (130, "l"),
            (140, "o"), (150, "space"), (160, "w"), (170, "o"),
            (180, "r"), (190, "l"), (200, "d"),
        ]);
        let wf = events_to_workflow(&evs, "t");
        assert_eq!(wf.steps.len(), 1);
        match &wf.steps[0].action {
            Action::WdoType { text, .. } => assert_eq!(text, "hello world"),
            other => panic!("expected WdoType, got {other:?}"),
        }
    }

    #[test]
    fn ctrl_l_then_text_then_return_emits_three_steps() {
        let evs = keys(&[
            (100, "ctrl+l"),
            (200, "h"), (210, "i"),
            (300, "Return"),
        ]);
        let wf = events_to_workflow(&evs, "t");
        // ctrl+l (key), Delay (gap >= 200 may or may not insert),
        // hi (type), Return (key). Allow Delay between for now.
        let mut keys = 0;
        let mut types = 0;
        for s in &wf.steps {
            match &s.action {
                Action::WdoKey { .. } => keys += 1,
                Action::WdoType { .. } => types += 1,
                _ => {}
            }
        }
        // ctrl+l and Return are real chords; "hi" coalesces.
        assert_eq!(keys, 2);
        assert_eq!(types, 1);
    }
}
