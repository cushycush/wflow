//! `wflow run` and the daemon-internal `wflow trigger-fire` wrapper.
//!
//! Handles workflow loading (path-or-id resolution), trust prompting,
//! preflight checks, the live event sink that prints per-step
//! outcomes, and the explain-mode rendering of the subprocess command
//! line each step would invoke.

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;

use anyhow::{anyhow, Context, Result};

use crate::actions::{Action, RunEvent, StepOutcome, Workflow};
use crate::{engine, kdl_format, security, store};

use super::{arrow, bold, check, cross, dim, dot, plural_s, which, wrap};

pub(super) fn cmd_run(target: &str, dry_run: bool, explain: bool, yes: bool) -> Result<ExitCode> {
    let wf = load_target(target)?;

    if explain {
        println!("{} {} (explain)", arrow(), bold(&wf.title));
        let w = if wf.steps.is_empty() {
            1
        } else {
            (wf.steps.len().ilog10() as usize) + 1
        };
        for (i, step) in wf.steps.iter().enumerate() {
            let num = format!("{:0>w$}", i + 1, w = w);
            if !step.enabled {
                println!("  {} {} {}", num, dim("·"), dim(&format!("(disabled) {}", step.action.describe())));
                continue;
            }
            for line in explain_lines(&step.action) {
                println!("  {} {}", num, line);
            }
        }
        return Ok(ExitCode::SUCCESS);
    }

    if dry_run {
        println!("{} {} (dry run)", arrow(), bold(&wf.title));
        for (i, step) in wf.steps.iter().enumerate() {
            println!(
                "  {:02} {:<9} {}",
                i + 1,
                step.action.category(),
                step.action.describe()
            );
        }
        println!("{} would execute {} step(s)", check(), wf.steps.len());
        return Ok(ExitCode::SUCCESS);
    }

    if wf.steps.is_empty() {
        println!("{} nothing to run", dim("—"));
        return Ok(ExitCode::SUCCESS);
    }

    preflight(&wf)?;

    // Trust check — require explicit confirmation the first time we
    // run a workflow file we didn't author here. `wflow new` and the
    // GUI editor mark their own files trusted on save, so this only
    // fires for files brought in from outside (downloaded, cloned,
    // hand-edited). --yes bypasses, for cron and scripted use.
    let trust_path = resolve_trust_path(target, &wf)?;
    let mode = if yes {
        security::TrustMode::Yes
    } else {
        security::TrustMode::Cli
    };
    match security::check_trust(&trust_path, mode)? {
        security::TrustDecision::Trusted => {}
        security::TrustDecision::Untrusted { canonical_path, hash } => {
            if !confirm_untrusted_workflow(&canonical_path, &wf)? {
                eprintln!("{} cancelled by user", cross());
                return Ok(ExitCode::from(2));
            }
            security::mark_trusted(&canonical_path, &hash)?;
        }
    }

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("tokio runtime")?;

    // The sink receives RunEvents in order from inside run_workflow. We
    // print them as they land so progress is live. `ran` counts
    // StepDone events — the post-flatten number, which may exceed
    // wf.steps.len() when `repeat` blocks expand.
    let title = wf.title.clone();
    let failed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let failed_c = failed.clone();
    let ran = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let ran_c = ran.clone();

    let sink: engine::EventSink = Arc::new(move |ev| print_event(&title, &ran_c, &failed_c, ev));

    runtime.block_on(async move { engine::run_workflow(sink, wf).await })?;

    if failed.load(std::sync::atomic::Ordering::SeqCst) {
        return Ok(ExitCode::from(2));
    }
    Ok(ExitCode::SUCCESS)
}

/// Daemon-side dispatch wrapper. Compositor binds (Hyprland, Sway,
/// portal) point at `wflow trigger-fire <id>` instead of `wflow run`
/// so we can gate on the workflow's `trigger.when` predicate before
/// firing. The bind itself is global because no Wayland compositor
/// exposes per-window hotkey grabs.
///
/// Predicate semantics:
///   - No `when` clause: fire as if predicate held.
///   - `window-class="x"`: fire iff the focused window's class
///     contains `x`, case-insensitive.
///   - `window-title="x"`: fire iff the focused window's title
///     contains `x`, case-insensitive.
///   - Probe failed (no Hyprland / Sway IPC reachable): fire anyway,
///     fail-open. KDE / GNOME portal users get the chord without
///     gating until the per-DE probe lands.
///
/// A skipped fire is silent (exit 0, single tracing::info! line) so
/// the chord registers as a no-op rather than a noisy failure on
/// every press in the wrong window.
pub(super) fn cmd_trigger_fire(target: &str) -> Result<ExitCode> {
    use crate::actions::{TriggerCondition, TriggerKind};

    let wf = match load_target(target) {
        Ok(wf) => wf,
        Err(e) => {
            tracing::warn!(target, ?e, "trigger-fire: load failed");
            return Ok(ExitCode::SUCCESS);
        }
    };

    // The chord that fired might be one of several triggers on the
    // same workflow — we don't know which. If any chord-trigger has
    // no `when`, fire. If every chord-trigger has a `when`, fire only
    // if at least one matches.
    let chord_triggers: Vec<_> = wf
        .triggers
        .iter()
        .filter(|t| matches!(t.kind, TriggerKind::Chord { .. }))
        .collect();

    if chord_triggers.is_empty() {
        return cmd_run(target, false, false, true);
    }

    let any_unconditional = chord_triggers.iter().any(|t| t.when.is_none());
    if any_unconditional {
        return cmd_run(target, false, false, true);
    }

    let active = crate::active_window::probe();
    if active.is_none() {
        tracing::debug!(
            target,
            "trigger-fire: no active-window probe available; firing without gate"
        );
        return cmd_run(target, false, false, true);
    }

    let active = active.unwrap();
    let matched = chord_triggers.iter().any(|t| match &t.when {
        Some(TriggerCondition::WindowClass { class }) => {
            active.class.to_lowercase().contains(&class.to_lowercase())
        }
        Some(TriggerCondition::WindowTitle { title }) => {
            active.title.to_lowercase().contains(&title.to_lowercase())
        }
        None => true,
    });

    if !matched {
        tracing::info!(
            target,
            class = %active.class,
            title = %active.title,
            "trigger-fire: predicate did not match focused window; skipping"
        );
        return Ok(ExitCode::SUCCESS);
    }

    cmd_run(target, false, false, true)
}

// ────────────────────────── target resolution + trust ─────────────────────────

/// Resolve TARGET to a `Workflow`. Tries path first — if it contains a
/// slash, ends in `.kdl`, or exists on disk. Otherwise looks the id up
/// in the library.
pub(super) fn load_target(target: &str) -> Result<Workflow> {
    let path_ish = target.contains('/') || target.ends_with(".kdl");
    let as_path = PathBuf::from(target);

    if path_ish || as_path.exists() {
        return load_file(&as_path)
            .with_context(|| format!("couldn't read {}", as_path.display()));
    }

    store::load(target).with_context(|| {
        format!(
            "no workflow with id `{target}` in library; try `wflow list` or pass a .kdl file path"
        )
    })
}

fn load_file(p: &Path) -> Result<Workflow> {
    match p.extension().and_then(|s| s.to_str()) {
        Some("json") => {
            let text =
                std::fs::read_to_string(p).with_context(|| format!("read {}", p.display()))?;
            serde_json::from_str(&text)
                .with_context(|| format!("parse json {}", p.display()))
        }
        // KDL path: resolves the workflow's `imports { ... }` block
        // and splices `use NAME` references at decode time.
        _ => kdl_format::decode_from_file(p),
    }
}

/// Resolve TARGET to the on-disk file path the trust check should
/// hash. Mirrors `load_target`'s precedence: path first, library id
/// second.
fn resolve_trust_path(target: &str, wf: &Workflow) -> Result<PathBuf> {
    let path_ish = target.contains('/') || target.ends_with(".kdl");
    let as_path = PathBuf::from(target);
    if path_ish || as_path.exists() {
        return Ok(as_path);
    }
    store::path_of(&wf.id).with_context(|| {
        format!("resolving on-disk path for library workflow `{}`", wf.id)
    })
}

/// Print a summary of the workflow's risky steps and ask the user to
/// confirm. Returns Ok(true) if the user typed yes. Errors out (rather
/// than silently denying) when stdin is not a TTY — a non-interactive
/// caller should pass `--yes` instead of hanging on a prompt that
/// will never resolve.
fn confirm_untrusted_workflow(path: &Path, wf: &Workflow) -> Result<bool> {
    use std::io::IsTerminal;

    if !std::io::stdin().is_terminal() {
        anyhow::bail!(
            "workflow {} hasn't run on this machine before; pass --yes for non-interactive use \
             (or run `wflow show {}` and `wflow run --explain {}` first to inspect)",
            path.display(),
            path.display(),
            path.display()
        );
    }

    eprintln!();
    eprintln!(
        "{} {} hasn't run on this machine before.",
        wrap("33", "!"),
        bold(&path.display().to_string())
    );
    eprintln!("  Title:  {}", wf.title);
    eprintln!("  Steps:  {}", wf.steps.len());
    eprintln!();
    eprintln!("  This workflow will:");
    let mut shown = 0usize;
    for step in &wf.steps {
        if !step.enabled {
            continue;
        }
        let kind = step.action.category();
        let marker = match kind {
            "shell" | "clipboard" => wrap("31", "•"),
            _ => dim("•"),
        };
        eprintln!("    {} {:<9} {}", marker, kind, step.action.describe());
        shown += 1;
        if shown >= 12 {
            eprintln!(
                "    {} ... and {} more (run `wflow show {}` for the full list)",
                dim("…"),
                wf.steps.len() - shown,
                path.display()
            );
            break;
        }
    }
    eprintln!();
    eprintln!(
        "  Tip: `wflow run --explain {}` shows the exact subprocess commands.",
        path.display()
    );
    eprintln!();
    eprint!("Run? [y/N] ");
    std::io::Write::flush(&mut std::io::stderr()).ok();

    let mut answer = String::new();
    std::io::stdin()
        .read_line(&mut answer)
        .context("reading confirmation from stdin")?;
    let yes = matches!(answer.trim(), "y" | "Y" | "yes" | "Yes" | "YES");
    Ok(yes)
}

// ──────────────────────────────── preflight ──────────────────────────────────

/// Refuse to start a run if the workflow needs a host binary that
/// isn't on PATH (notify-send, wl-copy). Input/window actions go
/// through wdotool-core in-process so they don't appear here — their
/// failure mode is "no backend reachable", caught at first dispatch.
fn preflight(wf: &Workflow) -> Result<()> {
    use std::collections::BTreeSet;
    let mut needed: BTreeSet<&'static str> = BTreeSet::new();
    collect_tool_needs(&wf.steps, &mut needed);
    let missing: Vec<&'static str> = needed.iter().filter(|t| which(t).is_none()).copied().collect();
    if missing.is_empty() {
        return Ok(());
    }
    Err(anyhow!(
        "missing required tool{}: {} — run `wflow doctor` for details",
        if missing.len() == 1 { "" } else { "s" },
        missing.join(", "),
    ))
}

/// Walk steps (recursing through `repeat` and `when`/`unless` blocks)
/// and collect the set of external binaries the workflow needs.
fn collect_tool_needs(
    steps: &[crate::actions::Step],
    needed: &mut std::collections::BTreeSet<&'static str>,
) {
    for step in steps {
        if !step.enabled {
            continue;
        }
        match &step.action {
            // Input/window actions go through wdotool-core in-process,
            // so they need no external binary.
            Action::WdoType { .. }
            | Action::WdoKey { .. }
            | Action::WdoKeyDown { .. }
            | Action::WdoKeyUp { .. }
            | Action::WdoClick { .. }
            | Action::WdoMouseDown { .. }
            | Action::WdoMouseUp { .. }
            | Action::WdoMouseMove { .. }
            | Action::WdoScroll { .. }
            | Action::WdoActivateWindow { .. }
            | Action::WdoAwaitWindow { .. } => {}
            Action::Notify { .. } => {
                needed.insert("notify-send");
            }
            Action::Clipboard { .. } => {
                needed.insert("wl-copy");
            }
            Action::Repeat { steps: inner, .. } => {
                collect_tool_needs(inner, needed);
            }
            Action::Conditional { steps: inner, .. } => {
                collect_tool_needs(inner, needed);
            }
            // `use` should be expanded by load_file; if one survived
            // here, preflight has nothing to report but should not
            // crash.
            Action::Use { .. } => {}
            Action::Shell { .. } | Action::Delay { .. } | Action::Note { .. } => {}
        }
    }
}

// ─────────────────────────────── live event sink ─────────────────────────────

fn print_event(
    title: &str,
    ran: &Arc<std::sync::atomic::AtomicUsize>,
    failed: &Arc<std::sync::atomic::AtomicBool>,
    ev: RunEvent,
) {
    match ev {
        RunEvent::Started { .. } => {
            println!("{} {}", arrow(), bold(title));
        }
        RunEvent::StepStart { .. } => {
            // Quiet on StepStart — only print the outcome so the line
            // can carry the success/error glyph.
        }
        RunEvent::StepDone {
            index, outcome, ..
        } => {
            ran.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let num = format!("{:02}", index + 1);
            match outcome {
                StepOutcome::Ok { output, duration_ms } => {
                    println!(
                        "  {} {} {}  {}",
                        check(),
                        num,
                        fmt_duration(duration_ms),
                        dim("ok")
                    );
                    if let Some(out) = output {
                        for line in out.lines().take(8) {
                            println!("       {}", dim(line));
                        }
                    }
                }
                StepOutcome::Skipped { reason } => {
                    println!("  {} {}        {}", dot(), num, dim(&reason));
                }
                StepOutcome::Error { message, duration_ms } => {
                    failed.store(true, std::sync::atomic::Ordering::SeqCst);
                    println!(
                        "  {} {} {}  {}",
                        cross(),
                        num,
                        fmt_duration(duration_ms),
                        message
                    );
                }
            }
        }
        RunEvent::Paused { .. } => {
            // The CLI never runs in debug mode; this branch keeps the
            // match exhaustive.
        }
        RunEvent::Finished { ok, .. } => {
            let n = ran.load(std::sync::atomic::Ordering::SeqCst);
            if ok {
                println!("{} finished ({} step{})", check(), n, plural_s(n));
            } else {
                println!("{} failed", cross());
            }
        }
    }
}

// ───────────────────────────────── explain ───────────────────────────────────

/// Build the subprocess command line(s) that the engine would invoke
/// for `action`, formatted as one or more shell-quoted strings ready
/// to print. In-process actions (delay, note, await-window, clipboard)
/// come back as a comment-style line so explain output stays
/// one-row-per-thing.
pub(super) fn explain_lines(action: &Action) -> Vec<String> {
    let cat = action.category();
    let head = format!("{:<9}", cat);
    match action {
        Action::WdoType { text, delay_ms } => {
            let mut a = vec!["wdotool".to_string(), "type".into()];
            if let Some(d) = delay_ms {
                a.push("--delay".into());
                a.push(d.to_string());
            }
            a.push("--".into());
            a.push(text.clone());
            vec![format!("{head} $ {}", join_argv(&a))]
        }
        Action::WdoKey { chord, clear_modifiers } => {
            let mut a = vec!["wdotool".to_string(), "key".into()];
            if *clear_modifiers {
                a.push("--clearmodifiers".into());
            }
            a.push(chord.clone());
            vec![format!("{head} $ {}", join_argv(&a))]
        }
        Action::WdoKeyDown { chord } => {
            let a = ["wdotool".to_string(), "keydown".into(), chord.clone()];
            vec![format!("{head} $ {}", join_argv(&a))]
        }
        Action::WdoKeyUp { chord } => {
            let a = ["wdotool".to_string(), "keyup".into(), chord.clone()];
            vec![format!("{head} $ {}", join_argv(&a))]
        }
        Action::WdoClick { button } => {
            let a = ["wdotool".to_string(), "click".into(), button.to_string()];
            vec![format!("{head} $ {}", join_argv(&a))]
        }
        Action::WdoMouseDown { button } => {
            let a = ["wdotool".to_string(), "mousedown".into(), button.to_string()];
            vec![format!("{head} $ {}", join_argv(&a))]
        }
        Action::WdoMouseUp { button } => {
            let a = ["wdotool".to_string(), "mouseup".into(), button.to_string()];
            vec![format!("{head} $ {}", join_argv(&a))]
        }
        Action::WdoMouseMove { x, y, relative } => {
            let mut a = vec!["wdotool".to_string(), "mousemove".into()];
            if *relative {
                a.push("--relative".into());
            }
            a.push(x.to_string());
            a.push(y.to_string());
            vec![format!("{head} $ {}", join_argv(&a))]
        }
        Action::WdoScroll { dx, dy } => {
            let a = ["wdotool".to_string(), "scroll".into(), dx.to_string(), dy.to_string()];
            vec![format!("{head} $ {}", join_argv(&a))]
        }
        Action::WdoActivateWindow { name } => {
            // Two subprocesses: search returns the id, windowactivate uses it.
            let search = ["wdotool".to_string(), "search".into(), "--limit".into(), "1".into(), "--name".into(), name.clone()];
            vec![
                format!("{head} $ {}", join_argv(&search)),
                format!("{:<9} $ wdotool windowactivate <id>", ""),
            ]
        }
        Action::WdoAwaitWindow { name, timeout_ms } => {
            let search = ["wdotool".to_string(), "search".into(), "--limit".into(), "1".into(), "--name".into(), name.clone()];
            vec![format!(
                "{head} # poll every 100ms for up to {}ms\n  {:<9} $ {}",
                timeout_ms,
                "",
                join_argv(&search),
            )]
        }
        Action::Delay { ms } => vec![format!("{head} # sleep {ms}ms (in-process)")],
        Action::Shell {
            command,
            shell,
            capture_as,
            timeout_ms,
            retries,
            backoff_ms,
        } => {
            let sh = shell
                .clone()
                .or_else(|| std::env::var("SHELL").ok())
                .unwrap_or_else(|| "/bin/sh".into());
            let a = [sh, "-c".into(), command.clone()];
            let mut line = format!("{head} $ {}", join_argv(&a));
            if let Some(ms) = timeout_ms {
                line.push_str(&format!(
                    "  (timeout {})",
                    crate::actions::fmt_duration_ms(*ms)
                ));
            }
            if *retries > 0 {
                let b = backoff_ms.unwrap_or(500);
                line.push_str(&format!(
                    "  (retries {}× backoff {})",
                    retries,
                    crate::actions::fmt_duration_ms(b)
                ));
            }
            if let Some(name) = capture_as {
                line.push_str(&format!("  → stdout captured as {{{{{name}}}}}"));
            }
            vec![line]
        }
        Action::Notify { title, body } => {
            let mut a = vec!["notify-send".to_string(), title.clone()];
            if let Some(b) = body {
                a.push(b.clone());
            }
            vec![format!("{head} $ {}", join_argv(&a))]
        }
        Action::Clipboard { text } => {
            // wl-copy reads stdin; show the equivalent here-string form.
            vec![format!("{head} $ printf %s {} | wl-copy", shell_quote(text))]
        }
        Action::Note { text } => {
            let one_line = text.replace('\n', " ↵ ");
            vec![format!("{head} # {}", one_line)]
        }
        Action::Repeat { count, steps } => {
            let mut lines = vec![format!(
                "{head} # repeat {count}× ({} step{})",
                steps.len(),
                if steps.len() == 1 { "" } else { "s" }
            )];
            indent_inner(steps, &mut lines);
            lines
        }
        Action::Conditional { cond, negate, steps, else_steps } => {
            let verb = if *negate { "unless" } else { "when" };
            let mut lines = vec![format!(
                "{head} # {verb} {} ({} step{})",
                cond.describe(),
                steps.len(),
                if steps.len() == 1 { "" } else { "s" }
            )];
            indent_inner(steps, &mut lines);
            if !else_steps.is_empty() {
                lines.push(format!(
                    "{head} # else ({} step{})",
                    else_steps.len(),
                    if else_steps.len() == 1 { "" } else { "s" }
                ));
                indent_inner(else_steps, &mut lines);
            }
            lines
        }
        Action::Use { name } => {
            vec![format!("{head} # use {}", name)]
        }
    }
}

fn indent_inner(steps: &[crate::actions::Step], lines: &mut Vec<String>) {
    for step in steps {
        let sub_head = format!("{:<9}", step.action.category());
        for (i, line) in explain_lines(&step.action).into_iter().enumerate() {
            let tail = line.trim_start_matches(&sub_head).trim_start();
            let first_prefix = if i == 0 { "  · " } else { "    " };
            lines.push(format!("{:<9} {first_prefix}{}", "", tail));
        }
    }
}

fn join_argv(argv: &[String]) -> String {
    argv.iter().map(|a| shell_quote(a)).collect::<Vec<_>>().join(" ")
}

/// POSIX-ish shell quoting. Bare for safe alphanum-ish strings,
/// otherwise single-quoted with embedded single quotes escaped as
/// `'\''`.
fn shell_quote(s: &str) -> String {
    if s.is_empty() {
        return "''".into();
    }
    let safe = s.chars().all(|c| {
        c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '/' | '.' | ':' | ',' | '+' | '=' | '@' | '%')
    });
    if safe {
        return s.to_string();
    }
    let escaped = s.replace('\'', "'\\''");
    format!("'{escaped}'")
}

fn fmt_duration(ms: u64) -> String {
    if ms < 1000 {
        format!("{ms}ms")
    } else {
        let secs = ms as f64 / 1000.0;
        format!("{secs:.2}s")
    }
}
