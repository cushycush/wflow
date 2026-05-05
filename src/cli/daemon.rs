//! `wflow daemon`. Single-instance, walks the library, registers
//! every chord trigger via Hyprland/Sway IPC or the GlobalShortcuts
//! portal, hot-reloads on file change. Ctrl+C unbinds cleanly.

use std::process::ExitCode;
use std::sync::Arc;

use anyhow::{Context, Result};

use crate::actions::Workflow;
use crate::store;
use crate::triggers::Binding;

use super::{arrow, bold, check, cross, dim, plural_s};

pub(super) fn cmd_daemon() -> Result<ExitCode> {
    use crate::actions::{TriggerCondition, TriggerKind};

    // Pidfile guards against a second daemon binding the same chords
    // (which the portal rejects loudly).
    let _lock = match crate::daemon_lock::try_acquire()? {
        crate::daemon_lock::AcquireOutcome::Acquired(g) => g,
        crate::daemon_lock::AcquireOutcome::AlreadyRunning { pid } => {
            println!("wflow daemon already running (pid {pid})");
            return Ok(ExitCode::SUCCESS);
        }
    };

    let workflows = store::list().context("reading library")?;

    // Collect every (workflow, trigger) pair, with display metadata.
    struct Row {
        binding: Binding,
        label: String,
        when_label: Option<String>,
    }

    let mut rows: Vec<Row> = Vec::new();
    let mut wf_count = 0usize;
    for wf in &workflows {
        if wf.triggers.is_empty() {
            continue;
        }
        wf_count += 1;
        for t in &wf.triggers {
            let label = match &t.kind {
                TriggerKind::Chord { chord } => chord.clone(),
                TriggerKind::Hotstring { text } => format!("hotstring {text:?}"),
            };
            let when_label = t.when.as_ref().map(|c| match c {
                TriggerCondition::WindowClass { class } => {
                    format!("when window-class={class:?}")
                }
                TriggerCondition::WindowTitle { title } => {
                    format!("when window-title={title:?}")
                }
            });
            rows.push(Row {
                binding: Binding {
                    workflow_id: wf.id.clone(),
                    workflow_title: wf.title.clone(),
                    trigger: t.clone(),
                },
                label,
                when_label,
            });
        }
    }

    println!("{}", bold("wflow daemon"));
    println!();

    if rows.is_empty() {
        println!("  {} no triggers declared in your library", dim("·"));
        println!();
        println!(
            "  Add a `trigger {{ chord \"...\" }}` block to a workflow's KDL\n  \
             to bind it to a global hotkey."
        );
        return Ok(ExitCode::SUCCESS);
    }

    println!(
        "  {} trigger{} across {} workflow{}:",
        rows.len(),
        plural_s(rows.len()),
        wf_count,
        plural_s(wf_count),
    );
    println!();
    let label_w = rows.iter().map(|r| r.label.len()).max().unwrap_or(0).max(8);
    for r in &rows {
        let when_suffix = match &r.when_label {
            Some(s) => format!("  {}", dim(&format!("[{s}]"))),
            None => String::new(),
        };
        println!(
            "  {:label_w$}  {}  {}{}",
            r.label,
            arrow(),
            r.binding.workflow_title,
            when_suffix,
            label_w = label_w
        );
    }
    println!();

    // IPC first, portal second. xdg-desktop-portal-hyprland advertises
    // GlobalShortcuts but doesn't actually wire activation, so a
    // portal-first probe binds ghost chords on Hyprland. IPC socket
    // detection skips that whole class of false-positive.
    let dispatchable: Vec<Binding> = rows
        .iter()
        .filter(|r| r.binding.is_dispatchable_today())
        .map(|r| r.binding.clone())
        .collect();
    let ipc_detected = crate::triggers::detect().is_some();

    if !ipc_detected && !dispatchable.is_empty() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .context("build tokio runtime for portal probe")?;
        let portal_available = rt.block_on(crate::triggers::portal::is_available());
        if portal_available {
            println!(
                "  {} using GlobalShortcuts portal. The first activation pops a\n  \
                 consent dialog from your desktop; accept it to enable the chords.",
                dim("·")
            );
            println!();
            match rt.block_on(crate::triggers::portal::run(dispatchable.clone())) {
                Ok(summary) => {
                    println!();
                    if summary.skipped_non_chord > 0 {
                        println!(
                            "  {} skipped {} non-chord trigger{} (hotstrings ship in v0.5)",
                            dim("·"),
                            summary.skipped_non_chord,
                            plural_s(summary.skipped_non_chord),
                        );
                    }
                    println!(
                        "  {} clean shutdown ({} binding{} were registered)",
                        check(),
                        summary.registered,
                        plural_s(summary.registered),
                    );
                    return Ok(ExitCode::SUCCESS);
                }
                Err(e) => {
                    println!("  {} portal failed: {e:#}", cross());
                    println!();
                    return Ok(ExitCode::FAILURE);
                }
            }
        }
    }

    // Compositor IPC backend (Hyprland, Sway).
    let mut backend = match crate::triggers::detect() {
        Some(b) => {
            println!(
                "  {} using {} compositor IPC backend",
                dim("·"),
                b.name()
            );
            println!();
            b
        }
        None => {
            println!(
                "  {} No trigger backend available. The GlobalShortcuts portal isn't\n  \
                 reachable, and no Hyprland or Sway IPC socket was detected.",
                dim("·")
            );
            return Ok(ExitCode::SUCCESS);
        }
    };

    // Hotstrings are forward-compat metadata; skip with a note. Chord
    // when-predicates are honored by the trigger-fire wrapper now.
    let mut registered: Vec<Binding> = Vec::new();
    for r in rows {
        if !r.binding.is_dispatchable_today() {
            println!(
                "  {} skip {} (not yet supported by the {} backend)",
                dim("·"),
                r.label,
                backend.name()
            );
            continue;
        }
        match backend.bind(&r.binding) {
            Ok(()) => registered.push(r.binding),
            Err(e) => println!("  {} bind {} failed: {e:#}", cross(), r.label),
        }
    }

    println!();
    if registered.is_empty() {
        // No triggers yet but stay alive; file watcher catches the
        // first one the user authors. Exiting here (the v0.7 way)
        // broke first-run UX: systemd-launched daemon would exit on
        // empty library, then any trigger added that session silently
        // didn't fire until next graphical-session boot.
        println!(
            "  {} no triggers to bind yet. Watching the library, \
             the daemon will pick up the first {} you author.",
            dim("·"),
            "trigger { chord \"…\" }",
        );
    } else {
        println!(
            "  {} {} binding{} registered with {}. Edit a workflow's KDL and the daemon\n  \
             picks up the change; Ctrl+C to unbind and exit.",
            check(),
            registered.len(),
            plural_s(registered.len()),
            backend.name(),
        );
    }

    // notify fires per-fsop; drain per tick and diff once.
    let (watch_tx, watch_rx) = std::sync::mpsc::channel::<()>();
    let watch_path = store::workflows_dir().ok();
    let _watcher = match watch_path {
        Some(ref dir) => {
            use notify::Watcher;
            let tx = watch_tx.clone();
            match notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
                if res.is_ok() {
                    let _ = tx.send(());
                }
            }) {
                Ok(mut w) => match w.watch(dir, notify::RecursiveMode::NonRecursive) {
                    Ok(()) => {
                        tracing::info!(path = %dir.display(), "watching workflow library for hot-reload");
                        Some(w)
                    }
                    Err(e) => {
                        tracing::warn!(?e, "couldn't watch workflow dir; hot-reload disabled");
                        None
                    }
                },
                Err(e) => {
                    tracing::warn!(?e, "couldn't init file watcher; hot-reload disabled");
                    None
                }
            }
        }
        None => {
            tracing::warn!("no workflow library path; hot-reload disabled");
            None
        }
    };

    // Block until SIGINT/SIGTERM. Sync, since Hyprland/Sway fire
    // workflows in separate subprocesses; the daemon mostly sleeps.
    let term = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let term_for_handler = term.clone();
    let _ = ctrlc::set_handler(move || {
        term_for_handler.store(true, std::sync::atomic::Ordering::SeqCst);
    });
    while !term.load(std::sync::atomic::Ordering::SeqCst) {
        std::thread::sleep(std::time::Duration::from_millis(250));

        // Editor saves fire 2-4 events in a burst; one tick is enough.
        let mut changed = false;
        while watch_rx.try_recv().is_ok() {
            changed = true;
        }
        if !changed {
            continue;
        }

        // Re-read the library and reconcile.
        let new_workflows = match store::list() {
            Ok(w) => w,
            Err(e) => {
                println!("  {} reload failed: {e:#}", cross());
                continue;
            }
        };
        let new_bindings = collect_dispatchable_bindings(&new_workflows);

        // Chord moving between workflows reads as remove + add.
        let mut current_by_chord: std::collections::HashMap<String, Binding> =
            std::collections::HashMap::new();
        for b in &registered {
            if let TriggerKind::Chord { chord } = &b.trigger.kind {
                current_by_chord.insert(chord.clone(), b.clone());
            }
        }
        let mut next_by_chord: std::collections::HashMap<String, Binding> =
            std::collections::HashMap::new();
        for b in &new_bindings {
            if let TriggerKind::Chord { chord } = &b.trigger.kind {
                // First-write-wins on chord collisions. Mirrors the
                // initial-bind loop's behavior.
                next_by_chord.entry(chord.clone()).or_insert_with(|| b.clone());
            }
        }

        let mut to_remove: Vec<Binding> = Vec::new();
        let mut to_add: Vec<Binding> = Vec::new();
        for (chord, old) in &current_by_chord {
            match next_by_chord.get(chord) {
                None => to_remove.push(old.clone()),
                Some(new) if new.workflow_id != old.workflow_id => {
                    // Re-target: unbind the old one so the new bind
                    // doesn't conflict with whatever the compositor
                    // thinks is bound to the chord.
                    to_remove.push(old.clone());
                    to_add.push(new.clone());
                }
                _ => {}
            }
        }
        for (chord, new) in &next_by_chord {
            if !current_by_chord.contains_key(chord) {
                to_add.push(new.clone());
            }
        }

        if to_remove.is_empty() && to_add.is_empty() {
            continue;
        }

        for b in &to_remove {
            if let Err(e) = backend.unbind(b) {
                tracing::warn!(?e, workflow = %b.workflow_id, "reload: unbind failed");
            }
        }
        let mut new_registered: Vec<Binding> = registered
            .iter()
            .filter(|b| !to_remove.iter().any(|r| same_chord(r, b)))
            .cloned()
            .collect();
        for b in &to_add {
            match backend.bind(b) {
                Ok(()) => new_registered.push(b.clone()),
                Err(e) => println!("  {} reload: bind failed: {e:#}", cross()),
            }
        }
        registered = new_registered;
        println!(
            "  {} reloaded, {} active binding{}",
            dim("·"),
            registered.len(),
            plural_s(registered.len()),
        );
    }

    println!();
    println!("  {} unbinding…", dim("·"));
    for b in &registered {
        if let Err(e) = backend.unbind(b) {
            tracing::warn!(?e, "unbind failed");
        }
    }
    println!("  {} clean shutdown", check());
    Ok(ExitCode::SUCCESS)
}

/// Every chord-trigger pair as a Binding. Reload loop uses this to
/// rebuild the desired-bindings set from disk.
fn collect_dispatchable_bindings(workflows: &[Workflow]) -> Vec<Binding> {
    use crate::actions::TriggerKind;
    let mut out = Vec::new();
    for wf in workflows {
        for t in &wf.triggers {
            if matches!(t.kind, TriggerKind::Chord { .. }) {
                out.push(Binding {
                    workflow_id: wf.id.clone(),
                    workflow_title: wf.title.clone(),
                    trigger: t.clone(),
                });
            }
        }
    }
    out
}

fn same_chord(a: &Binding, b: &Binding) -> bool {
    use crate::actions::TriggerKind;
    match (&a.trigger.kind, &b.trigger.kind) {
        (TriggerKind::Chord { chord: ca }, TriggerKind::Chord { chord: cb }) => ca == cb,
        _ => false,
    }
}
