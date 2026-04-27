//! Wflow-side recorder. Wraps `wdotool_core::recorder` (portal / evdev /
//! simulated input) and merges in compositor-specific focus events. Owns
//! the trailing-stop trim and `events_to_workflow` coercion. Set
//! `WFLOW_SIM_RECORDER=1` to force the simulated source.

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context as _, Result};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;
use tokio::task::JoinHandle;
use wdotool_core::recorder::{
    self as core_rec, BackendChoice, RecorderConfig, RecorderSession,
};

use crate::actions::{Action, Step, Workflow};

/// Bridge owns the Qt signal emission; we just hand it frames.
pub type FrameSink = Arc<dyn Fn(RecFrame) + Send + Sync>;

/// `MoveAbs` and `MoveDelta` collapse into one `Move { x, y }`; replay
/// chooses delta vs absolute via the action-level `relative` flag.
/// `WindowFocus`, `Text`, and `Gap` are wflow-side, not core.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RecEvent {
    /// Coalesced from modifier + key state.
    Key { t_ms: u64, chord: String },
    /// Coalesced from printable keystrokes during workflow construction.
    Text { t_ms: u64, text: String },
    Click { t_ms: u64, button: u8 },
    /// Absolute coords from portal, accumulated deltas from evdev.
    Move { t_ms: u64, x: i32, y: i32 },
    /// `dy>0` is down, `dx>0` is right.
    Scroll { t_ms: u64, dx: i32, dy: i32 },
    /// Compositor-specific. Hyprland subscriber today.
    WindowFocus { t_ms: u64, name: String },
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RecFrame {
    Armed,
    Started,
    Event { event: RecEvent },
    /// User pressed Super+Esc in the captured stream. Bridge
    /// invokes `Recorder::stop` from a fresh task.
    StopRequested,
    Stopped { reason: String, total_ms: u64 },
}

#[derive(Default)]
pub struct Recorder {
    inner: Mutex<Option<Session>>,
}

struct Session {
    events: Arc<Mutex<Vec<RecEvent>>>,
    started_at: Instant,
    /// `.stop()` or drop, either tears down the portal / evdev pump.
    core: Option<RecorderSession>,
    tasks: Vec<JoinHandle<()>>,
}

impl Recorder {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn start(&self, sink: FrameSink) -> Result<()> {
        {
            let slot = self.inner.lock().await;
            if slot.is_some() {
                anyhow::bail!("a recording session is already in progress");
            }
        }

        sink(RecFrame::Armed);

        let force_sim = std::env::var("WFLOW_SIM_RECORDER").ok().as_deref() == Some("1");
        let mut config = RecorderConfig::default();
        if force_sim {
            tracing::info!("recorder: WFLOW_SIM_RECORDER=1, using simulated backend");
            config.backend = BackendChoice::Simulated;
        }

        let mut core_session = match core_rec::start(config).await {
            Ok(s) => s,
            Err(e) => {
                let msg = format!("{e}");
                anyhow::bail!(msg);
            }
        };

        sink(RecFrame::Started);

        let started_at = core_session.started_at();
        let events: Arc<Mutex<Vec<RecEvent>>> = Default::default();

        let mut stream = core_session.events();
        let pump_events = events.clone();
        let pump_sink = sink.clone();
        let pump = tokio::spawn(async move {
            while let Some(core_ev) = stream.next().await {
                // Super+Esc stops without recording the press. Plain
                // Esc stays recordable so dialog-closing workflows work.
                if let core_rec::RecEvent::Key { chord, .. } = &core_ev {
                    if chord_is_super_escape(chord) {
                        pump_sink(RecFrame::StopRequested);
                        break;
                    }
                }
                let Some(ev) = translate_core_event(core_ev) else {
                    continue;
                };
                pump_events.lock().await.push(ev.clone());
                pump_sink(RecFrame::Event { event: ev });
            }
        });

        let mut tasks = vec![pump];

        // Compositor focus subscriber. Hyprland today; KWin / GNOME
        // can plug in here.
        if let Some(path) = hyprland_socket_path() {
            let events_h = events.clone();
            let sink_h = sink.clone();
            let h = tokio::spawn(async move {
                if let Err(e) = hyprland_subscribe(&path, started_at, events_h, sink_h).await {
                    tracing::warn!(error = %format!("{e:#}"), "hyprland subscriber exited");
                }
            });
            tasks.push(h);
        }

        let mut slot = self.inner.lock().await;
        *slot = Some(Session {
            events,
            started_at,
            core: Some(core_session),
            tasks,
        });
        Ok(())
    }

    /// Stop the current session. Returns the captured events in order.
    pub async fn stop(&self, sink: FrameSink, reason: &str) -> Result<Vec<RecEvent>> {
        let mut slot = self.inner.lock().await;
        let mut sess = slot.take().ok_or_else(|| anyhow!("not recording"))?;

        // Tear down the core session first so its pump exits and
        // closes the stream, that lets the wflow pump task drain.
        if let Some(core) = sess.core.take() {
            // We took the stream via events() during start(), so
            // core.stop()'s drain returns empty. We still call it
            // for the explicit stop signal + thread join.
            let _ = core.stop().await;
        }

        // Abort wflow-side tasks (pump may already be done; Hyprland
        // subscriber is unbounded). Give them a short grace period
        // so any in-flight events land in the buffer before we read
        // it.
        for t in &sess.tasks {
            t.abort();
        }
        for t in sess.tasks.drain(..) {
            let _ = tokio::time::timeout(Duration::from_millis(50), t).await;
        }

        let total_ms = sess.started_at.elapsed().as_millis() as u64;
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
}

// Translation helpers.

fn translate_core_event(ev: core_rec::RecEvent) -> Option<RecEvent> {
    Some(match ev {
        core_rec::RecEvent::Key { t_ms, chord } => RecEvent::Key { t_ms, chord },
        core_rec::RecEvent::Click { t_ms, button } => RecEvent::Click { t_ms, button },
        // Portal path is already absolute.
        core_rec::RecEvent::MoveAbs { t_ms, x, y } => RecEvent::Move { t_ms, x, y },
        // evdev path is delta accumulation; user fixes at edit time.
        core_rec::RecEvent::MoveDelta { t_ms, dx, dy } => RecEvent::Move { t_ms, x: dx, y: dy },
        core_rec::RecEvent::Scroll { t_ms, dx, dy } => RecEvent::Scroll { t_ms, dx, dy },
        core_rec::RecEvent::Gap { t_ms, ms } => RecEvent::Gap { t_ms, ms },
    })
}

/// Forgiving on modifier order and Escape case.
fn chord_is_super_escape(chord: &str) -> bool {
    let lower = chord.to_ascii_lowercase();
    lower.contains("super") && lower.ends_with("escape")
}

/// Cuts the trailing alt-tab + click-Stop-button sequence by truncating
/// at the LAST `WindowFocus { name: "wflow" }` event. A real workflow
/// won't have wflow focused mid-recording (you can't operate the
/// target app and wflow at once).
fn trim_stop_tail(events: &mut Vec<RecEvent>, _total_ms: u64) {
    let mut cut: Option<usize> = None;
    for (i, ev) in events.iter().enumerate() {
        if let RecEvent::WindowFocus { name, .. } = ev {
            if name.eq_ignore_ascii_case("wflow") {
                cut = Some(i);
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
        let mut events = vec![
            RecEvent::WindowFocus { t_ms: 100, name: "wflow".into() },
            RecEvent::Key { t_ms: 200, chord: "a".into() },
            RecEvent::WindowFocus { t_ms: 800, name: "firefox".into() },
            RecEvent::Key { t_ms: 900, chord: "b".into() },
            RecEvent::WindowFocus { t_ms: 1500, name: "wflow".into() },
            RecEvent::Click { t_ms: 1600, button: 1 },
        ];
        trim_stop_tail(&mut events, 1700);
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

// Compositor events.

/// `None` when not under Hyprland or the socket is missing.
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

/// `activewindow` and `openwindow` become `WindowFocus`. Everything
/// else drops. Consecutive same-class focuses dedupe.
async fn hyprland_subscribe(
    path: &std::path::Path,
    started_at: Instant,
    events: Arc<Mutex<Vec<RecEvent>>>,
    sink: FrameSink,
) -> Result<()> {
    use tokio::io::{AsyncBufReadExt, BufReader};
    use tokio::net::UnixStream;
    let stream = UnixStream::connect(path)
        .await
        .with_context(|| format!("connect Hyprland event socket {}", path.display()))?;
    let reader = BufReader::new(stream);
    let mut lines = reader.lines();
    let mut last_class = String::new();
    while let Some(line) = lines.next_line().await? {
        let Some((name, data)) = line.split_once(">>") else { continue };
        let t_ms = started_at.elapsed().as_millis() as u64;
        let class = match name {
            "activewindow" => data.split_once(',').map(|(c, _t)| c.to_string()),
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

// Events → Workflow.

/// Cleanup rules:
/// - Gap > 200ms → `wait`.
/// - Adjacent `Text` events concatenate.
/// - Single typeable Key chords coalesce into one `type`.
/// - WindowFocus → `focus` + 150ms grace `wait`.
pub fn events_to_workflow(events: &[RecEvent], title: &str) -> Workflow {
    let mut wf = Workflow::new(title);
    wf.subtitle = Some("recorded, cleanup recommended".into());

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
                // recording fires before focus has actually moved.
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
/// printable Key events back into a single `type` action.
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
        let mut keys = 0;
        let mut types = 0;
        for s in &wf.steps {
            match &s.action {
                Action::WdoKey { .. } => keys += 1,
                Action::WdoType { .. } => types += 1,
                _ => {}
            }
        }
        assert_eq!(keys, 2);
        assert_eq!(types, 1);
    }
}

#[cfg(test)]
mod chord_tests {
    use super::*;

    #[test]
    fn super_escape_is_recognised() {
        assert!(chord_is_super_escape("super+Escape"));
        assert!(chord_is_super_escape("Super+escape"));
        assert!(chord_is_super_escape("ctrl+super+Escape"));
    }

    #[test]
    fn plain_escape_is_not_super_escape() {
        assert!(!chord_is_super_escape("Escape"));
        assert!(!chord_is_super_escape("ctrl+Escape"));
        assert!(!chord_is_super_escape("super+a"));
    }
}
