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

use crate::actions::{substitute, Action, RunEvent, StepOutcome, VarMap, Workflow};

/// A thread-safe event sink. Implemented by the bridge layer so the Qt
/// signal path owns the threading concerns; the engine stays pure Rust.
pub type EventSink = Arc<dyn Fn(RunEvent) + Send + Sync>;

/// Run a workflow to completion (or first hard error).
pub async fn run_workflow(sink: EventSink, wf: Workflow) -> Result<()> {
    let run_id = Uuid::new_v4().to_string();

    sink(RunEvent::Started {
        workflow_id: wf.id.clone(),
        run_id: run_id.clone(),
    });

    // Run-time variable environment. Starts from the workflow's `vars {}`
    // block; grows as `shell "..." as="name"` steps capture their stdout.
    let mut vars: VarMap = wf.vars.clone();

    let mut all_ok = true;
    for (idx, step) in wf.steps.iter().enumerate() {
        sink(RunEvent::StepStart {
            step_id: step.id.clone(),
            index: idx,
        });

        let outcome = if !step.enabled {
            StepOutcome::Skipped {
                reason: "disabled".into(),
            }
        } else if matches!(step.action, Action::Note { .. }) {
            StepOutcome::Skipped {
                reason: "note".into(),
            }
        } else {
            // Substitute {{name}} before dispatch so both the runtime
            // and any captured output see the expanded form.
            match expand(&step.action, &vars) {
                Ok(expanded) => {
                    let outcome = run_action_value(&expanded).await;
                    // On success, if this is a `shell ... as="k"` step,
                    // bind its stdout for later steps.
                    if let (
                        StepOutcome::Ok { output: Some(out), .. },
                        Action::Shell { capture_as: Some(name), .. },
                    ) = (&outcome, &expanded)
                    {
                        vars.insert(name.clone(), out.trim_end().to_string());
                    } else if let (
                        StepOutcome::Ok { output: None, .. },
                        Action::Shell { capture_as: Some(name), .. },
                    ) = (&outcome, &expanded)
                    {
                        // No stdout → bind empty string rather than leaving
                        // the name unbound; later `{{name}}` substitutes "".
                        vars.insert(name.clone(), String::new());
                    }
                    outcome
                }
                Err(e) => StepOutcome::Error {
                    message: format!("{e:#}"),
                    duration_ms: 0,
                },
            }
        };

        if matches!(outcome, StepOutcome::Error { .. }) {
            all_ok = false;
        }

        sink(RunEvent::StepDone {
            step_id: step.id.clone(),
            index: idx,
            outcome: outcome.clone(),
        });

        if matches!(outcome, StepOutcome::Error { .. }) {
            break;
        }
    }

    sink(RunEvent::Finished {
        run_id: run_id.clone(),
        ok: all_ok,
    });
    Ok(())
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
        Action::WdoClick { button } => Action::WdoClick { button: *button },
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
        Action::Shell { command, shell, capture_as } => Action::Shell {
            command: sub(command)?,
            shell: shell.clone(),
            capture_as: capture_as.clone(),
        },
        Action::Notify { title, body } => Action::Notify {
            title: sub(title)?,
            body: body.as_deref().map(sub).transpose()?,
        },
        Action::Clipboard { text } => Action::Clipboard { text: sub(text)? },
        Action::Note { text } => Action::Note { text: text.clone() },
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
        Action::WdoClick { button } => wdo_click(*button).await,
        Action::WdoMouseMove { x, y, relative } => wdo_mousemove(*x, *y, *relative).await,
        Action::WdoScroll { dx, dy } => wdo_scroll(*dx, *dy).await,
        Action::WdoActivateWindow { name } => wdo_activate(name).await,
        Action::WdoAwaitWindow { name, timeout_ms } => wdo_await_window(name, *timeout_ms).await,
        Action::Delay { ms } => {
            tokio::time::sleep(std::time::Duration::from_millis(*ms)).await;
            Ok(None)
        }
        Action::Shell { command, shell, .. } => shell_run(command, shell.as_deref()).await,
        Action::Notify { title, body } => notify(title, body.as_deref()).await,
        Action::Clipboard { text } => clipboard_copy(text).await,
        Action::Note { .. } => Ok(None),
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

async fn shell_run(command: &str, shell: Option<&str>) -> Result<Option<String>> {
    let sh = shell
        .map(String::from)
        .or_else(|| std::env::var("SHELL").ok())
        .unwrap_or_else(|| "/bin/sh".into());
    let output = Command::new(&sh)
        .arg("-c")
        .arg(command)
        .output()
        .await
        .with_context(|| format!("failed to spawn {sh}"))?;
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    if !output.status.success() {
        return Err(anyhow!(
            "{sh} exit {}: {}",
            output.status,
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
