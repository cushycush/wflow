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
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use uuid::Uuid;

use crate::actions::{substitute, Action, Condition, OnError, RunEvent, Step, StepOutcome, VarMap, Workflow};

/// A thread-safe event sink. Implemented by the bridge layer so the Qt
/// signal path owns the threading concerns; the engine stays pure Rust.
pub type EventSink = Arc<dyn Fn(RunEvent) + Send + Sync>;

/// Run a workflow to completion (or first halting error).
pub async fn run_workflow(sink: EventSink, wf: Workflow) -> Result<()> {
    let run_id = Uuid::new_v4().to_string();

    sink(RunEvent::Started {
        workflow_id: wf.id.clone(),
        run_id: run_id.clone(),
    });

    let mut vars: VarMap = wf.vars.clone();
    let mut index = 0usize;
    let mut any_failed = false;

    run_steps(
        &wf.steps,
        &sink,
        &mut vars,
        &mut index,
        &mut any_failed,
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
) -> BoxFuture<'a, Result<Flow>> {
    Box::pin(async move {
        for step in steps {
            // Flow-control actions get evaluated inline — their inner
            // steps become the ones that emit events.
            match &step.action {
                Action::Repeat { count, steps: inner } if step.enabled => {
                    for _ in 0..*count {
                        if run_steps(inner, sink, vars, index, any_failed).await? == Flow::Halt {
                            return Ok(Flow::Halt);
                        }
                    }
                    continue;
                }
                Action::Conditional { cond, negate, steps: inner } if step.enabled => {
                    let cond_holds = evaluate_condition(cond, vars)
                        .await
                        .unwrap_or(false);
                    if cond_holds ^ *negate {
                        if run_steps(inner, sink, vars, index, any_failed).await? == Flow::Halt {
                            return Ok(Flow::Halt);
                        }
                    }
                    continue;
                }
                _ => {}
            }

            // Leaf step: emit StepStart, dispatch, emit StepDone.
            let idx = *index;
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
                        let outcome = run_action_value(&expanded).await;
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
/// window="X"` does the right thing when wdotool is missing.
async fn evaluate_condition(cond: &Condition, vars: &VarMap) -> Result<bool> {
    match cond {
        Condition::Window { name } => {
            let name = substitute(name, vars)?;
            Ok(find_window_id(&name).await?.is_some())
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
        Action::Include { path } => Action::Include { path: path.clone() },
        Action::Use { name } => Action::Use { name: name.clone() },
    })
}

/// Dispatch a single (already-expanded) action. Measures wall-time.
/// Never panics. `run_action_value` is the post-substitution path;
/// callers that still have a raw Step should go through `run_workflow`.
async fn run_action_value(action: &Action) -> StepOutcome {
    let start = Instant::now();
    let result: Result<Option<String>> = match action {
        Action::WdoType { text, delay_ms } => wdo_type(text, *delay_ms).await,
        Action::WdoKey {
            chord,
            clear_modifiers,
        } => wdo_key(chord, *clear_modifiers).await,
        Action::WdoKeyDown { chord } => wdo_key_down(chord).await,
        Action::WdoKeyUp { chord } => wdo_key_up(chord).await,
        Action::WdoClick { button } => wdo_click(*button).await,
        Action::WdoMouseDown { button } => wdo_mouse_down(*button).await,
        Action::WdoMouseUp { button } => wdo_mouse_up(*button).await,
        Action::WdoMouseMove { x, y, relative } => wdo_mousemove(*x, *y, *relative).await,
        Action::WdoScroll { dx, dy } => wdo_scroll(*dx, *dy).await,
        Action::WdoActivateWindow { name } => wdo_activate(name).await,
        Action::WdoAwaitWindow { name, timeout_ms } => wdo_await_window(name, *timeout_ms).await,
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
        // include/use should have been expanded at decode time.
        // Reaching any of these here means something bypassed the path.
        Action::Repeat { .. }
        | Action::Conditional { .. }
        | Action::Include { .. }
        | Action::Use { .. } => Err(anyhow!(
            "internal: flow-control action reached dispatch (likely an unexpanded include / use)"
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

// ----------------------------- wdotool subprocess helpers ------------------

async fn wdo_type(text: &str, delay_ms: Option<u32>) -> Result<Option<String>> {
    let mut args = vec!["type".to_string()];
    if let Some(d) = delay_ms {
        args.push("--delay".into());
        args.push(d.to_string());
    }
    args.push("--".into()); // stop option parsing so a leading - is literal
    args.push(text.to_string());
    run_wdotool(&args).await
}

async fn wdo_key(chord: &str, clear_modifiers: bool) -> Result<Option<String>> {
    let mut args = vec!["key".to_string()];
    if clear_modifiers {
        args.push("--clearmodifiers".into());
    }
    args.push(chord.to_string());
    run_wdotool(&args).await
}

async fn wdo_click(button: u8) -> Result<Option<String>> {
    run_wdotool(&["click".into(), button.to_string()]).await
}

async fn wdo_key_down(chord: &str) -> Result<Option<String>> {
    run_wdotool(&["keydown".into(), chord.to_string()]).await
}

async fn wdo_key_up(chord: &str) -> Result<Option<String>> {
    run_wdotool(&["keyup".into(), chord.to_string()]).await
}

async fn wdo_mouse_down(button: u8) -> Result<Option<String>> {
    run_wdotool(&["mousedown".into(), button.to_string()]).await
}

async fn wdo_mouse_up(button: u8) -> Result<Option<String>> {
    run_wdotool(&["mouseup".into(), button.to_string()]).await
}

async fn wdo_mousemove(x: i32, y: i32, relative: bool) -> Result<Option<String>> {
    let mut args = vec!["mousemove".to_string()];
    if relative {
        args.push("--relative".into());
    }
    args.push(x.to_string());
    args.push(y.to_string());
    run_wdotool(&args).await
}

async fn wdo_scroll(dx: i32, dy: i32) -> Result<Option<String>> {
    run_wdotool(&["scroll".into(), dx.to_string(), dy.to_string()]).await
}

async fn wdo_activate(name: &str) -> Result<Option<String>> {
    // Search, then activate the first match.
    let id = find_window_id(name)
        .await?
        .ok_or_else(|| anyhow!("no window matching {name:?}"))?;
    run_wdotool(&["windowactivate".into(), id]).await
}

/// Poll wdotool for a matching window until it appears or the timeout
/// elapses. Returns Ok on success; on timeout returns an error so the
/// engine halts (the user's next step almost certainly relies on the
/// window being real).
async fn wdo_await_window(name: &str, timeout_ms: u64) -> Result<Option<String>> {
    use std::time::{Duration, Instant};
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let poll_every = Duration::from_millis(100);
    loop {
        if let Some(id) = find_window_id(name).await? {
            return Ok(Some(format!("window `{name}` at id {id}")));
        }
        if Instant::now() >= deadline {
            return Err(anyhow!(
                "no window matching {name:?} appeared within {timeout_ms}ms"
            ));
        }
        tokio::time::sleep(poll_every).await;
    }
}

async fn find_window_id(name: &str) -> Result<Option<String>> {
    // `wdotool search` prints one id per match; "no match" surfaces as a
    // non-zero exit, so treat NotFound / exit-error as "not yet there"
    // instead of a hard failure.
    let args = [
        "search".into(),
        "--limit".into(),
        "1".into(),
        "--name".into(),
        name.to_string(),
    ];
    match run_wdotool(&args).await {
        Ok(out) => Ok(out
            .as_deref()
            .and_then(|s| s.lines().next())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())),
        Err(_) => Ok(None),
    }
}

async fn run_wdotool(args: &[String]) -> Result<Option<String>> {
    let mut cmd = Command::new("wdotool");
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = cmd
        .spawn()
        .with_context(|| format!("failed to spawn wdotool {}", args.join(" ")))?;

    let mut stdout = String::new();
    let mut stderr = String::new();
    if let Some(mut o) = child.stdout.take() {
        o.read_to_string(&mut stdout).await.ok();
    }
    if let Some(mut e) = child.stderr.take() {
        e.read_to_string(&mut stderr).await.ok();
    }
    let status = child.wait().await?;
    if !status.success() {
        return Err(anyhow!(
            "wdotool {} failed ({}): {}",
            args.join(" "),
            status,
            stderr.trim()
        ));
    }
    Ok(if stdout.is_empty() {
        None
    } else {
        Some(stdout.trim().to_string())
    })
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

    let mut child = Command::new(&sh)
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

async fn notify(title: &str, body: Option<&str>) -> Result<Option<String>> {
    let mut cmd = Command::new("notify-send");
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

async fn clipboard_copy(text: &str) -> Result<Option<String>> {
    use tokio::io::AsyncWriteExt;
    let mut child = Command::new("wl-copy")
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
