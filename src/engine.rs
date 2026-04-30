//! Workflow execution engine.
//!
//! Runs a `Workflow`'s steps sequentially. Each step dispatches through
//! `run_action`, producing a `StepOutcome`. A caller-supplied `sink`
//! receives `RunEvent`s as they happen so the UI can light up the active
//! step and surface results in real time.

use std::process::Stdio;
use std::sync::Arc;
use std::time::Instant;

use anyhow::{anyhow, Context, Result};
use uuid::Uuid;

use crate::actions::{substitute, Action, Condition, OnError, RunEvent, Step, StepOutcome, VarMap, Workflow};
use crate::wdo::LazyBackend;

/// A thread-safe event sink. Implemented by the bridge layer so the Qt
/// signal path owns the threading concerns; the engine stays pure Rust.
pub type EventSink = Arc<dyn Fn(RunEvent) + Send + Sync>;

/// Commands the bridge can send to a running debug session. The engine
/// awaits the next one between steps when running under
/// [`PauseControl::on`].
#[derive(Debug, Clone, Copy)]
pub enum DebugCommand {
    /// Run the next single step, then pause again.
    Step,
    /// Run remaining steps without pausing.
    Continue,
    /// Halt the workflow immediately.
    Stop,
}

/// Threaded through every recursive `run_steps` call so the engine can
/// gate each step on a caller-supplied debug command channel without
/// the rest of the dispatch logic having to know about debug mode.
pub struct PauseControl {
    state: PauseState,
}

enum PauseState {
    /// Never pause; just run.
    Off,
    /// Pause before each step and wait for the next [`DebugCommand`].
    On(tokio::sync::mpsc::Receiver<DebugCommand>),
}

impl PauseControl {
    pub fn off() -> Self {
        Self { state: PauseState::Off }
    }
    pub fn on(rx: tokio::sync::mpsc::Receiver<DebugCommand>) -> Self {
        Self { state: PauseState::On(rx) }
    }

    /// Awaits before each step. Returns true to proceed, false to
    /// halt the workflow. If the user picks Continue we flip to Off
    /// so subsequent steps run without pausing.
    async fn gate(&mut self, sink: &EventSink, idx: usize) -> bool {
        match &mut self.state {
            PauseState::Off => true,
            PauseState::On(rx) => {
                sink(RunEvent::Paused { index: idx });
                match rx.recv().await {
                    Some(DebugCommand::Step) => true,
                    Some(DebugCommand::Continue) => {
                        self.state = PauseState::Off;
                        true
                    }
                    Some(DebugCommand::Stop) | None => false,
                }
            }
        }
    }
}

/// Run a workflow to completion (or first halting error).
pub async fn run_workflow(sink: EventSink, wf: Workflow) -> Result<()> {
    run_workflow_with(sink, wf, PauseControl::off()).await
}

/// Run a workflow under explicit pause control. Identical to
/// [`run_workflow`] when `pause` is `PauseControl::off`; with
/// `PauseControl::on` the engine pauses before each step and emits
/// [`RunEvent::Paused`] until the bridge sends a [`DebugCommand`].
pub async fn run_workflow_with(
    sink: EventSink,
    wf: Workflow,
    mut pause: PauseControl,
) -> Result<()> {
    let run_id = Uuid::new_v4().to_string();

    sink(RunEvent::Started {
        workflow_id: wf.id.clone(),
        run_id: run_id.clone(),
    });

    let mut vars: VarMap = wf.vars.clone();
    let mut index = 0usize;
    let mut any_failed = false;
    // One backend handle for the whole run. Initialization is deferred
    // until the first input action so workflows that don't touch
    // input (pure shell / notify / clipboard / wait pipelines) never
    // hit the libei portal prompt.
    let backend = LazyBackend::new();

    run_steps(
        &wf.steps,
        &sink,
        &mut vars,
        &mut index,
        &mut any_failed,
        &backend,
        &mut pause,
    )
    .await?;

    sink(RunEvent::Finished {
        run_id,
        ok: !any_failed,
    });
    Ok(())
}

/// Recursively dispatch a list of steps. Handles flow-control actions
/// (`repeat`, `when`/`unless`) inline so their inner steps emit their
/// own StepStart/StepDone events with continuous indices. Returns
/// `Flow::Halt` when a step fails with `on-error=stop`; that bubbles
/// up the recursion and terminates the whole workflow.
type BoxFuture<'a, T> = std::pin::Pin<Box<dyn std::future::Future<Output = T> + Send + 'a>>;

fn run_steps<'a>(
    steps: &'a [Step],
    sink: &'a EventSink,
    vars: &'a mut VarMap,
    index: &'a mut usize,
    any_failed: &'a mut bool,
    backend: &'a LazyBackend,
    pause: &'a mut PauseControl,
) -> BoxFuture<'a, Result<Flow>> {
    Box::pin(async move {
        for step in steps {
            // Flow-control actions get evaluated inline — their inner
            // steps become the ones that emit events.
            match &step.action {
                Action::Repeat { count, steps: inner } if step.enabled => {
                    for _ in 0..*count {
                        if run_steps(inner, sink, vars, index, any_failed, backend, pause).await? == Flow::Halt {
                            return Ok(Flow::Halt);
                        }
                    }
                    continue;
                }
                Action::Conditional { cond, negate, steps: inner } if step.enabled => {
                    let cond_holds = evaluate_condition(cond, vars, backend)
                        .await
                        .unwrap_or(false);
                    if cond_holds ^ *negate {
                        if run_steps(inner, sink, vars, index, any_failed, backend, pause).await? == Flow::Halt {
                            return Ok(Flow::Halt);
                        }
                    }
                    continue;
                }
                _ => {}
            }

            // Leaf step: emit StepStart, dispatch, emit StepDone.
            let idx = *index;
            // Debug pause point. In normal runs PauseControl::Off
            // returns true immediately; in debug runs we await the
            // next command. Stop / channel-closed both halt the run.
            //
            // Skip the gate for steps that will be skipped anyway
            // (notes and disabled steps). Otherwise debug mode would
            // pause on every annotation, which feels broken — the
            // debugger should walk only through steps that actually
            // execute.
            let will_run = step.enabled && !matches!(step.action, Action::Note { .. });
            if will_run && !pause.gate(sink, idx).await {
                return Ok(Flow::Halt);
            }
            *index += 1;
            sink(RunEvent::StepStart {
                step_id: step.id.clone(),
                index: idx,
            });

            let outcome = if !step.enabled {
                StepOutcome::Skipped { reason: "disabled".into() }
            } else if matches!(step.action, Action::Note { .. }) {
                StepOutcome::Skipped { reason: "note".into() }
            } else {
                match expand(&step.action, vars) {
                    Ok(expanded) => {
                        let outcome = run_action_value(&expanded, backend).await;
                        // Bind stdout to the `as=` var on shell success.
                        if let (
                            StepOutcome::Ok { output, .. },
                            Action::Shell { capture_as: Some(name), .. },
                        ) = (&outcome, &expanded)
                        {
                            let value = output
                                .clone()
                                .map(|s| s.trim_end().to_string())
                                .unwrap_or_default();
                            vars.insert(name.clone(), value);
                        }
                        outcome
                    }
                    Err(e) => StepOutcome::Error {
                        message: format!("{e:#}"),
                        duration_ms: 0,
                    },
                }
            };

            let errored = matches!(outcome, StepOutcome::Error { .. });
            if errored {
                *any_failed = true;
            }

            sink(RunEvent::StepDone {
                step_id: step.id.clone(),
                index: idx,
                outcome: outcome.clone(),
            });

            if errored && step.on_error == OnError::Stop {
                return Ok(Flow::Halt);
            }
        }
        Ok(Flow::Continue)
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Flow {
    Continue,
    Halt,
}

/// Test a `Condition` against live system state. Errors surface as
/// `Ok(false)` — we treat "can't tell" as "not true" so `unless
/// window="X"` does the right thing when no backend is available.
async fn evaluate_condition(cond: &Condition, vars: &VarMap, backend: &LazyBackend) -> Result<bool> {
    match cond {
        Condition::Window { name } => {
            let name = substitute(name, vars)?;
            Ok(crate::wdo::find_window_id(backend, &name).await?.is_some())
        }
        Condition::File { path } => {
            let path = substitute(path, vars)?;
            let resolved = expand_tilde(&path);
            Ok(resolved.exists())
        }
        Condition::Env { name, equals } => match std::env::var(name) {
            Err(_) => Ok(false),
            Ok(v) if v.is_empty() => Ok(false),
            Ok(v) => Ok(match equals {
                Some(target) => v == *target,
                None => true,
            }),
        },
    }
}

fn expand_tilde(p: &str) -> std::path::PathBuf {
    if let Some(rest) = p.strip_prefix("~/") {
        if let Some(home) = dirs::home_dir() {
            return home.join(rest);
        }
    }
    if p == "~" {
        if let Some(home) = dirs::home_dir() {
            return home;
        }
    }
    std::path::PathBuf::from(p)
}

/// Clone an action with all of its string fields `{{name}}`-expanded
/// against `vars`. Integer / boolean fields pass through untouched.
fn expand(action: &Action, vars: &VarMap) -> Result<Action> {
    let sub = |s: &str| substitute(s, vars);
    Ok(match action {
        Action::WdoType { text, delay_ms } => Action::WdoType {
            text: sub(text)?,
            delay_ms: *delay_ms,
        },
        Action::WdoKey { chord, clear_modifiers } => Action::WdoKey {
            chord: sub(chord)?,
            clear_modifiers: *clear_modifiers,
        },
        Action::WdoKeyDown { chord } => Action::WdoKeyDown { chord: sub(chord)? },
        Action::WdoKeyUp { chord } => Action::WdoKeyUp { chord: sub(chord)? },
        Action::WdoClick { button } => Action::WdoClick { button: *button },
        Action::WdoMouseDown { button } => Action::WdoMouseDown { button: *button },
        Action::WdoMouseUp { button } => Action::WdoMouseUp { button: *button },
        Action::WdoMouseMove { x, y, relative } => Action::WdoMouseMove {
            x: *x,
            y: *y,
            relative: *relative,
        },
        Action::WdoScroll { dx, dy } => Action::WdoScroll { dx: *dx, dy: *dy },
        Action::WdoActivateWindow { name } => Action::WdoActivateWindow { name: sub(name)? },
        Action::WdoAwaitWindow { name, timeout_ms } => Action::WdoAwaitWindow {
            name: sub(name)?,
            timeout_ms: *timeout_ms,
        },
        Action::Delay { ms } => Action::Delay { ms: *ms },
        Action::Shell {
            command,
            shell,
            capture_as,
            timeout_ms,
            retries,
            backoff_ms,
        } => Action::Shell {
            command: sub(command)?,
            shell: shell.clone(),
            capture_as: capture_as.clone(),
            timeout_ms: *timeout_ms,
            retries: *retries,
            backoff_ms: *backoff_ms,
        },
        Action::Notify { title, body } => Action::Notify {
            title: sub(title)?,
            body: body.as_deref().map(sub).transpose()?,
        },
        Action::Clipboard { text } => Action::Clipboard { text: sub(text)? },
        Action::Note { text } => Action::Note { text: text.clone() },
        // Flow-control actions are handled inline by `run_steps` so
        // reaching here would be a misuse. Clone through so the
        // function stays total.
        Action::Repeat { count, steps } => Action::Repeat {
            count: *count,
            steps: steps.clone(),
        },
        Action::Conditional { cond, negate, steps } => Action::Conditional {
            cond: cond.clone(),
            negate: *negate,
            steps: steps.clone(),
        },
        Action::Use { name } => Action::Use { name: name.clone() },
    })
}

/// Dispatch a single (already-expanded) action. Measures wall-time.
/// Never panics. `run_action_value` is the post-substitution path;
/// callers that still have a raw Step should go through `run_workflow`.
async fn run_action_value(action: &Action, backend: &LazyBackend) -> StepOutcome {
    use crate::wdo;
    let start = Instant::now();
    let result: Result<Option<String>> = match action {
        Action::WdoType { text, delay_ms } => wdo::wdo_type(backend, text, *delay_ms).await,
        Action::WdoKey {
            chord,
            clear_modifiers,
        } => wdo::wdo_key(backend, chord, *clear_modifiers).await,
        Action::WdoKeyDown { chord } => wdo::wdo_key_down(backend, chord).await,
        Action::WdoKeyUp { chord } => wdo::wdo_key_up(backend, chord).await,
        Action::WdoClick { button } => wdo::wdo_click(backend, *button).await,
        Action::WdoMouseDown { button } => wdo::wdo_mouse_down(backend, *button).await,
        Action::WdoMouseUp { button } => wdo::wdo_mouse_up(backend, *button).await,
        Action::WdoMouseMove { x, y, relative } => wdo::wdo_mousemove(backend, *x, *y, *relative).await,
        Action::WdoScroll { dx, dy } => wdo::wdo_scroll(backend, *dx, *dy).await,
        Action::WdoActivateWindow { name } => wdo::wdo_activate(backend, name).await,
        Action::WdoAwaitWindow { name, timeout_ms } => wdo::wdo_await_window(backend, name, *timeout_ms).await,
        Action::Delay { ms } => {
            tokio::time::sleep(std::time::Duration::from_millis(*ms)).await;
            Ok(None)
        }
        Action::Shell {
            command,
            shell,
            timeout_ms,
            retries,
            backoff_ms,
            ..
        } => {
            shell_run_with_retry(
                command,
                shell.as_deref(),
                *timeout_ms,
                *retries,
                *backoff_ms,
            )
            .await
        }
        Action::Notify { title, body } => notify(title, body.as_deref()).await,
        Action::Clipboard { text } => clipboard_copy(text).await,
        Action::Note { .. } => Ok(None),
        // Flow-control actions are handled inline by `run_steps`;
        // `use` should have been expanded at decode time. Reaching any
        // of these here means something bypassed the path.
        Action::Repeat { .. }
        | Action::Conditional { .. }
        | Action::Use { .. } => Err(anyhow!(
            "internal: flow-control action reached dispatch (likely an unexpanded `use`)"
        )),
    };
    let duration_ms = start.elapsed().as_millis() as u64;

    match result {
        Ok(output) => StepOutcome::Ok {
            output,
            duration_ms,
        },
        Err(e) => StepOutcome::Error {
            message: format!("{e:#}"),
            duration_ms,
        },
    }
}

// ----------------------------- system helpers -----------------------------

/// Wrap `shell_run` in a retry loop. `retries=3` means up to 4 total
/// attempts (one initial + three retries), with `backoff_ms` between
/// each. Backoff defaults to 500ms when retries > 0 and not given.
async fn shell_run_with_retry(
    command: &str,
    shell: Option<&str>,
    timeout_ms: Option<u64>,
    retries: u32,
    backoff_ms: Option<u64>,
) -> Result<Option<String>> {
    if retries == 0 {
        return shell_run(command, shell, timeout_ms).await;
    }
    let backoff = backoff_ms.unwrap_or(500);
    let total_attempts = retries + 1;
    let mut last_err: Option<anyhow::Error> = None;
    for attempt in 1..=total_attempts {
        match shell_run(command, shell, timeout_ms).await {
            Ok(v) => {
                if attempt > 1 {
                    tracing::info!(attempt, "shell succeeded on retry");
                }
                return Ok(v);
            }
            Err(e) => {
                tracing::warn!(attempt, ?e, "shell attempt failed");
                last_err = Some(e);
                if attempt < total_attempts {
                    tokio::time::sleep(std::time::Duration::from_millis(backoff)).await;
                }
            }
        }
    }
    Err(last_err.unwrap().context(format!(
        "gave up after {} attempt{}",
        total_attempts,
        if total_attempts == 1 { "" } else { "s" }
    )))
}

async fn shell_run(
    command: &str,
    shell: Option<&str>,
    timeout_ms: Option<u64>,
) -> Result<Option<String>> {
    use tokio::io::AsyncReadExt;

    let sh = shell
        .map(String::from)
        .or_else(|| std::env::var("SHELL").ok())
        .unwrap_or_else(|| "/bin/sh".into());

    let mut child = crate::host::host_command(&sh)
        .arg("-c")
        .arg(command)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("failed to spawn {sh}"))?;

    // Take the io handles up front so the wait future only borrows
    // the child's status machinery; that way select! can drop the
    // wait branch cleanly on timeout and we still reach child.kill.
    let mut stdout_h = child.stdout.take().unwrap();
    let mut stderr_h = child.stderr.take().unwrap();

    let status = match timeout_ms {
        Some(ms) => {
            let timer = tokio::time::sleep(std::time::Duration::from_millis(ms));
            tokio::select! {
                biased;
                res = child.wait() => res?,
                _ = timer => {
                    let _ = child.start_kill();
                    let _ = child.wait().await;
                    return Err(anyhow!(
                        "`shell` timed out after {} (command: `{}`)",
                        crate::actions::fmt_duration_ms(ms),
                        truncate_cmd(command)
                    ));
                }
            }
        }
        None => child.wait().await?,
    };

    let mut stdout_buf = String::new();
    let mut stderr_buf = String::new();
    stdout_h.read_to_string(&mut stdout_buf).await.ok();
    stderr_h.read_to_string(&mut stderr_buf).await.ok();
    let stdout = stdout_buf;
    let stderr = stderr_buf;
    let output_status = status;
    if !output_status.success() {
        return Err(anyhow!(
            "{sh} exit {}: {}",
            output_status,
            stderr.trim()
        ));
    }
    let combined = if stderr.trim().is_empty() {
        stdout
    } else {
        format!("{stdout}\n--- stderr ---\n{stderr}")
    };
    Ok(if combined.trim().is_empty() {
        None
    } else {
        Some(combined.trim().to_string())
    })
}

fn truncate_cmd(s: &str) -> String {
    const MAX: usize = 48;
    let single_line = s.replace('\n', " ↵ ");
    if single_line.chars().count() > MAX {
        let t: String = single_line.chars().take(MAX).collect();
        format!("{t}…")
    } else {
        single_line
    }
}

/// Inside a Flatpak sandbox we use `org.freedesktop.portal.Notification`
/// directly so we don't have to host-spawn notify-send. Outside the
/// sandbox, notify-send is universal and one less D-Bus connection
/// to manage. The two paths are functionally equivalent from the
/// user's perspective; the engine returns an Ok outcome either way.
async fn notify(title: &str, body: Option<&str>) -> Result<Option<String>> {
    if crate::host::in_flatpak() {
        return notify_via_portal(title, body).await;
    }
    let mut cmd = crate::host::host_command("notify-send");
    cmd.arg(title);
    if let Some(b) = body {
        cmd.arg(b);
    }
    let status = cmd.status().await.context("failed to run notify-send")?;
    if !status.success() {
        return Err(anyhow!("notify-send exit {status}"));
    }
    Ok(None)
}

async fn notify_via_portal(title: &str, body: Option<&str>) -> Result<Option<String>> {
    use ashpd::desktop::notification::{Notification, NotificationProxy};
    let proxy = NotificationProxy::new()
        .await
        .context("connect to org.freedesktop.portal.Notification")?;
    let mut n = Notification::new(title);
    if let Some(b) = body {
        n = n.body(b);
    }
    // Notification id is for later remove_notification calls; we don't
    // need that, so generate a one-shot id.
    let id = uuid::Uuid::new_v4().to_string();
    proxy
        .add_notification(&id, n)
        .await
        .context("portal add_notification")?;
    Ok(None)
}

async fn clipboard_copy(text: &str) -> Result<Option<String>> {
    use tokio::io::AsyncWriteExt;
    let mut child = crate::host::host_command("wl-copy")
        .stdin(Stdio::piped())
        .spawn()
        .context("failed to spawn wl-copy (is wl-clipboard installed?)")?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(text.as_bytes()).await?;
        stdin.shutdown().await?;
    }
    let status = child.wait().await?;
    if !status.success() {
        return Err(anyhow!("wl-copy exit {status}"));
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::actions::{Action, OnError, Step, Workflow};
    use std::sync::Mutex;

    fn note_step(id: &str) -> Step {
        Step {
            id: id.into(),
            enabled: true,
            note: None,
            on_error: OnError::Stop,
            action: Action::Note { text: "noop".into() },
        }
    }

    fn collect_events(wf: Workflow) -> Vec<RunEvent> {
        let collected = Arc::new(Mutex::new(Vec::<RunEvent>::new()));
        let sink_collected = collected.clone();
        let sink: EventSink = Arc::new(move |ev| {
            sink_collected.lock().unwrap().push(ev);
        });
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(run_workflow(sink, wf)).unwrap();
        let out = collected.lock().unwrap().clone();
        out
    }

    /// A `repeat { count = 3 }` containing one inner step should fire
    /// StepStart + StepDone three times — same step_id each iteration,
    /// continuous flat indices. The bridge's per-iteration pulse
    /// animation depends on this.
    #[test]
    fn repeat_emits_three_starts_with_stable_step_id() {
        let inner = note_step("inner-A");
        let repeat = Step {
            id: "repeat-1".into(),
            enabled: true,
            note: None,
            on_error: OnError::Stop,
            action: Action::Repeat {
                count: 3,
                steps: vec![inner],
            },
        };
        let mut wf = Workflow::new("test repeat");
        wf.steps = vec![repeat];

        let events = collect_events(wf);

        let starts: Vec<(usize, String)> = events
            .iter()
            .filter_map(|ev| match ev {
                RunEvent::StepStart { index, step_id } => Some((*index, step_id.clone())),
                _ => None,
            })
            .collect();
        let dones: Vec<(usize, String)> = events
            .iter()
            .filter_map(|ev| match ev {
                RunEvent::StepDone { index, step_id, .. } => {
                    Some((*index, step_id.clone()))
                }
                _ => None,
            })
            .collect();

        assert_eq!(
            starts.len(),
            3,
            "repeat count=3 should emit StepStart three times, got {starts:?}"
        );
        assert_eq!(starts.len(), dones.len(), "Start / Done counts should match");
        for (_, id) in &starts {
            assert_eq!(id, "inner-A", "step_id stays stable across iterations");
        }
        // Indices are continuous and increasing — the bridge keys
        // its flat-index status map off these values.
        assert_eq!(starts[0].0, 0);
        assert_eq!(starts[1].0, 1);
        assert_eq!(starts[2].0, 2);
    }

    /// StepDone now carries `step_id` so the QML can attach status
    /// dots to inner repeat steps that don't have a top-level card.
    /// Regression guard: every StepDone has a matching StepStart with
    /// the same id and index.
    #[test]
    fn step_done_carries_matching_step_id() {
        let mut wf = Workflow::new("test ids");
        wf.steps = vec![note_step("alpha"), note_step("beta")];
        let events = collect_events(wf);

        let mut pairs = Vec::<(String, String)>::new();
        let mut last_start: Option<(usize, String)> = None;
        for ev in &events {
            match ev {
                RunEvent::StepStart { index, step_id } => {
                    last_start = Some((*index, step_id.clone()));
                }
                RunEvent::StepDone {
                    index, step_id, ..
                } => {
                    let (s_idx, s_id) = last_start
                        .take()
                        .expect("StepDone without preceding StepStart");
                    assert_eq!(s_idx, *index, "Done index matches Start index");
                    pairs.push((s_id, step_id.clone()));
                }
                _ => {}
            }
        }
        assert_eq!(pairs.len(), 2);
        assert_eq!(pairs[0], ("alpha".into(), "alpha".into()));
        assert_eq!(pairs[1], ("beta".into(), "beta".into()));
    }
}
