//! Command-line interface.
//!
//! When `wflow` is invoked with a subcommand (`run`, `list`, `validate`,
//! `show`, `path`), we dispatch here and never bring up Qt. Plain
//! `wflow` with no arguments still launches the GUI from `main`.

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use clap::{CommandFactory, Parser, Subcommand};
use clap_complete::Shell;

use crate::actions::{Action, RunEvent, StepOutcome, Workflow};
use crate::{engine, kdl_format, security, store};

#[derive(Parser, Debug)]
#[command(
    name = "wflow",
    version,
    about = "A workflow engine for Wayland automation.",
    long_about = "wflow executes KDL workflow files — sequences of keystrokes, clicks, shell commands, delays, and notifications. Input/window actions go through the in-process wdotool-core engine; shell, notify-send, and wl-copy still subprocess to the host. \
Run `wflow` with no arguments to launch the GUI."
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Subcommand, Debug)]
pub enum Command {
    /// Execute a workflow by library id or KDL file path.
    ///
    /// Looks up TARGET as a file first, falls back to the library
    /// (~/.config/wflow/workflows).
    Run {
        /// Library id, or path to a .kdl file.
        target: String,
        /// Print what would run without executing anything.
        #[arg(long)]
        dry_run: bool,
        /// Print the exact subprocess command line each step would
        /// invoke, then exit without running. Implies --dry-run.
        #[arg(long)]
        explain: bool,
        /// Skip the first-run trust prompt for unfamiliar workflow
        /// files. Required for non-interactive use (cron, scripts).
        /// Workflows authored on this machine via `wflow new` or the
        /// GUI editor are always trusted automatically.
        #[arg(long)]
        yes: bool,
    },
    /// List workflows in the library.
    List {
        /// Emit JSON instead of a human table.
        #[arg(long)]
        json: bool,
    },
    /// Parse a workflow and report any errors. Does not execute.
    Validate {
        /// Library id, or path to a .kdl file.
        target: String,
    },
    /// Print the steps of a workflow in human-readable form.
    Show {
        /// Library id, or path to a .kdl file.
        target: String,
    },
    /// Print the workflows directory.
    Path,
    /// Open a workflow's KDL file in $VISUAL / $EDITOR (falls back to
    /// xdg-open). Accepts a library id or a path to a .kdl file.
    Edit {
        /// Library id, or path to a .kdl file.
        target: String,
    },
    /// Delete a workflow from the library by id. Prompts for
    /// confirmation on a TTY; pass --force to skip the prompt.
    Rm {
        /// Library id of the workflow to remove.
        target: String,
        /// Skip the confirmation prompt.
        #[arg(short, long)]
        force: bool,
    },
    /// Scaffold a new workflow KDL file in the library and print its path.
    New {
        /// Title for the new workflow (shown in `list` / editor).
        title: String,
        /// Print the generated KDL to stdout instead of writing to disk.
        #[arg(long)]
        stdout: bool,
    },
    /// Check that required binaries (wdotool, notify-send, wl-copy) are
    /// available on PATH. Useful as a preflight before shipping
    /// workflows to a new machine.
    Doctor,
    /// Print a shell completion script to stdout.
    ///
    /// Install (pick your shell):{n}
    ///   bash  →  source <(wflow completions bash){n}
    ///   zsh   →  wflow completions zsh  > "${fpath[1]}/_wflow"{n}
    ///   fish  →  wflow completions fish > ~/.config/fish/completions/wflow.fish
    ///
    /// The generated scripts include dynamic library-id completion,
    /// powered by `wflow ids`.
    Completions {
        /// Target shell.
        shell: Shell,
    },
    /// Print library workflows as `id<TAB>title`, one per line.
    ///
    /// Stable interface for shell completion (`wflow completions ...`)
    /// and external tooling. Use `wflow list` for human-readable output.
    Ids,
    /// Convert legacy-format workflow files in the library to the
    /// current format in place.
    ///
    /// The current format wraps each workflow in a single
    /// `workflow "Title" { ... }` node and stores `created` /
    /// `modified` / `last-run` timestamps in a sidecar TOML
    /// (`~/.config/wflow/workflows.toml`) instead of inside the file.
    /// Legacy files still parse (the decoder accepts both shapes), and
    /// they migrate lazily on the next save anyway. This subcommand is
    /// the explicit one-shot version for users who don't want to wait
    /// for lazy migration.
    ///
    /// Pass `--dry-run` to see what would change without writing.
    Migrate {
        /// Print the conversion plan without rewriting any files.
        #[arg(long)]
        dry_run: bool,
    },
    /// Generate the wflow(1) man page (and one page per subcommand).
    ///
    /// With no flags, writes the top-level page to stdout — fine for
    /// `wflow man | gzip > /usr/share/man/man1/wflow.1.gz`. Pass
    /// `--output DIR` to also emit per-subcommand pages
    /// (`wflow-run.1`, `wflow-list.1`, …) into DIR; packagers want this
    /// form.
    Man {
        /// Directory to write `wflow.1` plus one page per subcommand.
        /// When omitted, the top-level page is written to stdout.
        #[arg(long, value_name = "DIR")]
        output: Option<PathBuf>,
    },
    /// Walk the library, list every trigger declared in a workflow,
    /// and print what would be bound. Today's implementation is
    /// dry-run only — the v0.4 daemon will actually register the
    /// bindings via the GlobalShortcuts portal (or compositor IPC
    /// fallback) and dispatch workflows on activation.
    Daemon,
}

/// Top-level entry point from main(). Returns a process exit code.
pub fn run(cli: Cli) -> ExitCode {
    // Keep logging quiet by default so CLI output is clean; users can
    // still opt into verbose logs with RUST_LOG / WFLOW_LOG.
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("wflow=warn,error")),
        )
        .with_writer(std::io::stderr)
        .try_init();

    let result = match cli.command.expect("run called without a subcommand") {
        Command::Run { target, dry_run, explain, yes } => cmd_run(&target, dry_run, explain, yes),
        Command::List { json } => cmd_list(json),
        Command::Validate { target } => cmd_validate(&target),
        Command::Show { target } => cmd_show(&target),
        Command::Path => cmd_path(),
        Command::Edit { target } => cmd_edit(&target),
        Command::Rm { target, force } => cmd_rm(&target, force),
        Command::New { title, stdout } => cmd_new(&title, stdout),
        Command::Doctor => cmd_doctor(),
        Command::Completions { shell } => cmd_completions(shell),
        Command::Ids => cmd_ids(),
        Command::Migrate { dry_run } => cmd_migrate(dry_run),
        Command::Man { output } => cmd_man(output.as_deref()),
        Command::Daemon => cmd_daemon(),
    };

    match result {
        Ok(code) => code,
        Err(e) => {
            eprintln!("error: {e:#}");
            ExitCode::from(1)
        }
    }
}

// ------------------------------- Commands -----------------------------------

fn cmd_new(title: &str, to_stdout: bool) -> Result<ExitCode> {
    // Hand-written scaffold so we can mix freeform comments in with the
    // canonical KDL. The steps below are `disabled=#true` so running the
    // fresh workflow is a no-op until the user turns them on. Timestamps
    // live in workflows.toml; the file stays pure spec.
    let wf = Workflow::new(title);
    let template = format!(
        "// A wflow workflow. See `docs/KDL.md` for the full action vocabulary.\n\
         workflow \"{title}\" {{\n    \
             // Starter steps. `disabled=#true` keeps them inert so a fresh\n    \
             // `wflow run` is a no-op. Flip the flag off (or delete the line)\n    \
             // when you want a step to actually fire.\n    \
             notify \"hello from wflow\" disabled=#true\n    \
             shell \"echo 'wflow ran at ' \\\"$(date)\\\"\" disabled=#true\n    \
             wait-window \"Firefox\" timeout=\"5s\" disabled=#true\n    \
             key \"ctrl+l\" disabled=#true\n\
         }}\n",
        title = title.replace('"', "\\\""),
    );
    if to_stdout {
        print!("{template}");
        return Ok(ExitCode::SUCCESS);
    }
    // Persist to the library directory. We need to route through
    // store::save so the file lands with the canonical safe_id-based
    // filename, but save() does not accept a comment template. Shortcut:
    // save the plain workflow, then overwrite the file with the
    // template body in-place so the comments survive.
    let saved = store::save(wf).context("saving workflow")?;
    let base = dirs::config_dir().context("no XDG config dir")?;
    let file = base
        .join("wflow")
        .join("workflows")
        .join(format!("{}.kdl", saved.id.replace(['/', '\\', '.'], "_")));
    std::fs::write(&file, &template).with_context(|| format!("write {}", file.display()))?;
    println!("{}", file.display());
    eprintln!(
        "{} created `{}` — edit the file, then run `wflow run {}`",
        check(),
        title,
        saved.id
    );
    Ok(ExitCode::SUCCESS)
}

fn cmd_edit(target: &str) -> Result<ExitCode> {
    // Resolve to an on-disk path. If TARGET points at a real file, just
    // open that — handy for editing a workflow that isn't in the library
    // yet. Otherwise look it up by id.
    let as_path = PathBuf::from(target);
    let path = if as_path.exists() && (target.contains('/') || target.ends_with(".kdl")) {
        as_path
    } else {
        store::path_of(target).with_context(|| {
            format!("no workflow with id `{target}` in library; try `wflow list`")
        })?
    };

    // Defer to the shell so $EDITOR strings like "nvim --noplugin" or
    // "code --wait" word-split correctly. Empty $VISUAL/$EDITOR ⇒
    // xdg-open as a last resort.
    let editor = std::env::var("VISUAL")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| std::env::var("EDITOR").ok().filter(|s| !s.trim().is_empty()))
        .unwrap_or_else(|| "xdg-open".into());

    let status = std::process::Command::new("sh")
        .arg("-c")
        .arg(r#"exec $WFLOW_EDITOR "$@""#)
        .arg("wflow-edit")
        .arg(&path)
        .env("WFLOW_EDITOR", &editor)
        .status()
        .with_context(|| format!("failed to spawn editor `{editor}`"))?;

    if !status.success() {
        anyhow::bail!("editor `{editor}` exited {status}");
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_rm(target: &str, force: bool) -> Result<ExitCode> {
    // Resolve via load() so we get the real id + a friendly title for the
    // confirmation prompt, and so a typoed id errors out before we touch
    // the filesystem.
    let wf = store::load(target).with_context(|| {
        format!("no workflow with id `{target}` in library; try `wflow list`")
    })?;

    if !force {
        use std::io::{IsTerminal, Write};
        if !std::io::stdin().is_terminal() {
            anyhow::bail!("refusing to delete without a TTY; pass --force to override");
        }
        eprint!("delete `{}` ({})? [y/N] ", wf.title, wf.id);
        std::io::stderr().flush().ok();
        let mut answer = String::new();
        std::io::stdin().read_line(&mut answer)?;
        let yes = matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes");
        if !yes {
            eprintln!("{} cancelled", dim("—"));
            return Ok(ExitCode::SUCCESS);
        }
    }

    store::delete(&wf.id).context("removing workflow")?;
    eprintln!("{} deleted `{}` ({})", check(), wf.title, wf.id);
    Ok(ExitCode::SUCCESS)
}

fn cmd_doctor() -> Result<ExitCode> {
    // Two diagnostics here:
    //
    // 1. The input/window backend wflow links from wdotool-core. We
    //    DON'T actually call `detector::build` because that would
    //    trigger an XDG portal prompt; we just print the priority
    //    order so the user knows which backend the engine will try
    //    first on this compositor.
    //
    // 2. Host binaries the engine still subprocesses for (notify-send
    //    for desktop notifications, wl-copy for clipboard). Inside a
    //    Flatpak sandbox we probe via `flatpak-spawn --host -- which`
    //    so the report reflects what the engine will actually see.
    let in_flatpak = crate::host::in_flatpak();

    // ---- Backend probe (no portal) ----
    let env = wdotool_core::backend::detector::Environment::detect();
    let order = wdotool_core::backend::detector::priority(&env);
    let labels: Vec<&str> = order.iter().map(|k| k.label()).collect();
    if let Some((preferred, fallbacks)) = labels.split_first() {
        let trail = if fallbacks.is_empty() {
            String::new()
        } else {
            format!(" {}", dim(&format!("(fallbacks: {})", fallbacks.join(", "))))
        };
        println!("  {} backend  preferred = {}{}", check(), preferred, trail);
    }

    // ---- Host-binary probes ----
    let tools: &[(&str, &str)] = &[
        ("notify-send", "desktop notifications"),
        ("wl-copy", "clipboard (Wayland)"),
    ];

    if in_flatpak {
        println!("  {}", dim("(probing host PATH via flatpak-spawn)"));
    }

    let mut all_ok = true;
    let path_w = tools.iter().map(|(n, _)| n.len()).max().unwrap_or(0).max(8);
    let missing_label = if in_flatpak { "(not on host PATH)" } else { "(not on PATH)" };
    for (bin, role) in tools {
        match which_host(bin) {
            Some(p) => println!(
                "  {} {:path_w$}  {}  {}",
                check(),
                bin,
                dim(&p.display().to_string()),
                dim(role),
                path_w = path_w
            ),
            None => {
                all_ok = false;
                println!(
                    "  {} {:path_w$}  {}  {}",
                    cross(),
                    bin,
                    dim(missing_label),
                    dim(role),
                    path_w = path_w
                );
            }
        }
    }

    // ---- Workflow directory / count summary ----
    let base = dirs::config_dir().context("no XDG config dir")?;
    let dir = base.join("wflow").join("workflows");
    let count = std::fs::read_dir(&dir)
        .map(|d| d.filter(|e| e.is_ok()).count())
        .unwrap_or(0);
    println!();
    println!(
        "  library: {} ({} file{})",
        dir.display(),
        count,
        plural_s(count)
    );

    if all_ok {
        Ok(ExitCode::SUCCESS)
    } else {
        eprintln!(
            "\n{} some tools are missing — workflows using those actions will fail",
            cross()
        );
        Ok(ExitCode::from(1))
    }
}

fn cmd_ids() -> Result<ExitCode> {
    // Stable, parseable contract: `id\ttitle\n`. Tabs in titles are
    // replaced with spaces to keep the format unambiguous; titles
    // otherwise pass through unchanged. Used by shell completions and
    // anything else that wants to enumerate the library by id.
    let workflows = store::list().context("reading library")?;
    for wf in workflows {
        let title = wf.title.replace('\t', " ");
        println!("{}\t{}", wf.id, title);
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_completions(shell: Shell) -> Result<ExitCode> {
    use std::io::Write;
    let mut cmd = Cli::command();
    let bin_name = cmd.get_name().to_string();

    // Capture into a buffer so we can post-process before writing — zsh's
    // dynamic-completion path needs to swap `_default` for our id
    // completer on a few specific lines.
    let mut buf: Vec<u8> = Vec::new();
    clap_complete::generate(shell, &mut cmd, &bin_name, &mut buf);

    let mut out = std::io::stdout().lock();
    match shell {
        Shell::Fish => {
            out.write_all(&buf)?;
            out.write_all(FISH_DYNAMIC.as_bytes())?;
        }
        Shell::Bash => {
            out.write_all(&buf)?;
            out.write_all(BASH_DYNAMIC.as_bytes())?;
        }
        Shell::Zsh => {
            // Re-target the `_default` action on `target` args belonging
            // to subcommands that take a workflow id. Generated lines look
            // like `':target -- Library id, ...:_default'` — exactly one
            // per affected subcommand, so a literal replace is safe.
            let s = String::from_utf8(buf).context("non-utf8 zsh completion script")?;
            let s = s.replace(
                "':target -- Library id, or path to a .kdl file:_default'",
                "':target -- Library id, or path to a .kdl file:_wflow_ids'",
            );
            let s = s.replace(
                "':target -- Library id of the workflow to remove:_default'",
                "':target -- Library id of the workflow to remove:_wflow_ids'",
            );
            out.write_all(s.as_bytes())?;
            out.write_all(ZSH_DYNAMIC.as_bytes())?;
        }
        // Elvish + PowerShell: ship the static script, no dynamic hook.
        // Users who care can wire one with `wflow ids`.
        _ => {
            out.write_all(&buf)?;
        }
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_migrate(dry_run: bool) -> Result<ExitCode> {
    let workflows = store::list().context("listing workflows")?;
    if workflows.is_empty() {
        println!("library is empty — nothing to migrate");
        return Ok(ExitCode::SUCCESS);
    }

    let mut to_migrate: Vec<(String, String)> = Vec::new(); // (id, current_path)
    let mut already_new: Vec<String> = Vec::new();

    for wf in &workflows {
        let path = match store::path_of(&wf.id) {
            Ok(p) => p,
            Err(_) => continue,
        };
        // Detect by reading the raw text for the legacy shape — `recipe {`
        // or top-level `id "..."` / `schema 1` / etc. The decoder also
        // works as an oracle but reading the bytes is faster and lets us
        // print the path without re-decoding.
        let body = std::fs::read_to_string(&path).unwrap_or_default();
        let is_legacy = body.contains("\nrecipe ")
            || body.starts_with("recipe ")
            || body.contains("\nschema ")
            || body.starts_with("schema ");
        if is_legacy {
            to_migrate.push((wf.id.clone(), path.display().to_string()));
        } else {
            already_new.push(wf.id.clone());
        }
    }

    println!(
        "{} {} workflows total — {} legacy, {} already in the new format",
        arrow(),
        workflows.len(),
        to_migrate.len(),
        already_new.len()
    );

    if to_migrate.is_empty() {
        println!("{} nothing to do", check());
        return Ok(ExitCode::SUCCESS);
    }

    for (id, path) in &to_migrate {
        println!("  {} {} ({})", dim("→"), id, path);
    }

    if dry_run {
        println!();
        println!("{} dry run — pass without --dry-run to actually convert", arrow());
        return Ok(ExitCode::SUCCESS);
    }

    let mut converted = 0usize;
    let mut errors: Vec<(String, String)> = Vec::new();
    for (id, _path) in &to_migrate {
        match store::load(id) {
            Ok(wf) => match store::save(wf) {
                Ok(_) => converted += 1,
                Err(e) => errors.push((id.clone(), format!("{e:#}"))),
            },
            Err(e) => errors.push((id.clone(), format!("{e:#}"))),
        }
    }

    println!();
    println!("{} converted {}/{}", check(), converted, to_migrate.len());
    if !errors.is_empty() {
        println!("{} {} failures:", cross(), errors.len());
        for (id, msg) in &errors {
            println!("  {} {} — {}", cross(), id, msg);
        }
        return Ok(ExitCode::from(1));
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_man(output: Option<&Path>) -> Result<ExitCode> {
    use std::io::Write;
    let cmd = Cli::command();

    match output {
        None => {
            // Top-level page only, on stdout. The common
            // `wflow man | gzip > /usr/share/man/man1/wflow.1.gz` flow.
            // EPIPE (downstream `head` / `less` closed early) is normal
            // for a shell tool — exit 0 instead of an "error: Broken pipe".
            let mut out = std::io::stdout().lock();
            if let Err(e) = clap_mangen::Man::new(cmd).render(&mut out) {
                if e.kind() != std::io::ErrorKind::BrokenPipe {
                    return Err(e.into());
                }
            }
            Ok(ExitCode::SUCCESS)
        }
        Some(dir) => {
            std::fs::create_dir_all(dir)
                .with_context(|| format!("creating man output dir {}", dir.display()))?;
            // generate_to writes wflow.1 plus wflow-<sub>.1 for every subcommand.
            clap_mangen::generate_to(cmd, dir)
                .with_context(|| format!("writing man pages to {}", dir.display()))?;
            // Print the list of generated files so the caller (PKGBUILD,
            // Makefile) can sanity-check what landed.
            let mut entries: Vec<_> = std::fs::read_dir(dir)
                .with_context(|| format!("reading {}", dir.display()))?
                .filter_map(|e| e.ok())
                .map(|e| e.path())
                .filter(|p| p.extension().is_some_and(|x| x == "1"))
                .collect();
            entries.sort();
            let mut out = std::io::stdout().lock();
            for path in entries {
                writeln!(out, "{}", path.display())?;
            }
            Ok(ExitCode::SUCCESS)
        }
    }
}

/// Walk the library, collect every workflow's `trigger { }` blocks,
/// register them with the compositor (Hyprland today; Sway / KDE /
/// GNOME / portal in v0.5), and stay alive so chord activations
/// fire workflows. Ctrl+C or SIGTERM unbinds everything cleanly.
///
/// On compositors with no backend yet, falls back to a dry-run
/// listing so the user at least sees what WOULD be bound.
fn cmd_daemon() -> Result<ExitCode> {
    use crate::actions::{TriggerCondition, TriggerKind};
    use crate::triggers::Binding;

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

    let backend = crate::triggers::detect();
    let header = match &backend {
        Some(b) => format!("wflow daemon ({} backend)", b.name()),
        None => "wflow daemon (dry run, no backend for this compositor)".into(),
    };
    println!("{}", bold(&header));
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

    let mut backend = match backend {
        Some(b) => b,
        None => {
            println!(
                "  {} No trigger backend available for this compositor. wflow ships\n  \
                 a Hyprland backend today; Sway / KDE / GNOME land in a follow-up.",
                dim("·")
            );
            return Ok(ExitCode::SUCCESS);
        }
    };

    // Register every dispatchable binding. Skip hotstring + when
    // predicates with a one-line note — they're forward-compat
    // metadata in the KDL today.
    let mut registered: Vec<Binding> = Vec::new();
    for r in rows {
        if !r.binding.is_dispatchable_today() {
            println!("  {} skip {} (not yet supported by the {} backend)",
                dim("·"), r.label, backend.name());
            continue;
        }
        if r.binding.trigger.when.is_some() {
            println!(
                "  {} {} bound globally; per-window `when` predicate ignored for now",
                dim("·"), r.label
            );
        }
        match backend.bind(&r.binding) {
            Ok(()) => registered.push(r.binding),
            Err(e) => println!("  {} bind {} failed: {e:#}", cross(), r.label),
        }
    }

    if registered.is_empty() {
        println!();
        println!("  {} nothing to subscribe to — exiting", dim("·"));
        return Ok(ExitCode::SUCCESS);
    }

    println!();
    println!(
        "  {} {} binding{} registered with {}. Press Ctrl+C to unbind and exit.",
        check(),
        registered.len(),
        plural_s(registered.len()),
        backend.name(),
    );

    // Block until SIGINT / SIGTERM. Keeping it sync (no tokio) since
    // there's nothing else to drive — Hyprland fires the workflow in
    // a separate `wflow run` subprocess, so the daemon literally
    // just sleeps.
    let term = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let term_for_handler = term.clone();
    let _ = ctrlc::set_handler(move || {
        term_for_handler.store(true, std::sync::atomic::Ordering::SeqCst);
    });
    while !term.load(std::sync::atomic::Ordering::SeqCst) {
        std::thread::sleep(std::time::Duration::from_millis(250));
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

// Subcommands that take a library id as their first positional. Kept
// here as a comment-grep target so future commands can be added to the
// shell snippets below: run, show, validate, edit, rm.

const FISH_DYNAMIC: &str = r#"
# Dynamic library-id completion (added by `wflow completions fish`).
complete -c wflow -n "__fish_wflow_using_subcommand run show validate edit rm" -f -a "(wflow ids 2>/dev/null)"
"#;

const BASH_DYNAMIC: &str = r#"
# Dynamic library-id completion (added by `wflow completions bash`).
# Wraps the clap-generated `_wflow` so subcommands taking a workflow id
# tab-complete from `wflow ids` instead of falling through to filenames.
# Falls through to `_wflow` for flags (cur starts with `-`) and for any
# position other than the subcommand argument.
_wflow_with_ids() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    if [ "${COMP_CWORD}" -eq 2 ] && [[ "${cur}" != -* ]]; then
        case "${COMP_WORDS[1]}" in
            run|show|validate|edit|rm)
                local ids
                ids=$(wflow ids 2>/dev/null | cut -f1)
                COMPREPLY=( $(compgen -W "${ids}" -- "${cur}") )
                return 0
                ;;
        esac
    fi
    _wflow "$@"
}
complete -F _wflow_with_ids -o nosort -o bashdefault -o default wflow 2>/dev/null \
    || complete -F _wflow_with_ids -o bashdefault -o default wflow
"#;

const ZSH_DYNAMIC: &str = r#"
# Dynamic library-id completion (added by `wflow completions zsh`).
# Referenced by the `:_wflow_ids` action injected on `target` arguments
# for run/show/validate/edit/rm.
_wflow_ids() {
    local -a entries
    local id title
    while IFS=$'\t' read -r id title; do
        [ -n "$id" ] && entries+=("${id}:${title}")
    done < <(wflow ids 2>/dev/null)
    _describe -t workflows 'workflow' entries
}
"#;

fn which(bin: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for entry in std::env::split_paths(&path) {
        let candidate = entry.join(bin);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// Like `which`, but in a Flatpak sandbox probes the host's PATH via
/// `flatpak-spawn --host -- /usr/bin/which <bin>` so doctor reports
/// what the engine will actually see at run time. Outside a sandbox
/// this is a plain `which`.
fn which_host(bin: &str) -> Option<PathBuf> {
    if !crate::host::in_flatpak() {
        return which(bin);
    }
    // `which` is the canonical lookup tool on every distro Flathub
    // targets. We don't go through host_command here because that's
    // tokio-only and doctor is sync.
    let output = std::process::Command::new("flatpak-spawn")
        .args(["--host", "--", "which", bin])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let s = std::str::from_utf8(&output.stdout).ok()?.trim();
    if s.is_empty() {
        None
    } else {
        Some(PathBuf::from(s))
    }
}

fn cmd_path() -> Result<ExitCode> {
    // Match store::workflows_dir but we don't expose it publicly yet.
    let base = dirs::config_dir().context("no XDG config dir")?;
    let dir = base.join("wflow").join("workflows");
    println!("{}", dir.display());
    Ok(ExitCode::SUCCESS)
}

fn cmd_list(as_json: bool) -> Result<ExitCode> {
    let workflows = store::list().context("reading library")?;

    if as_json {
        #[derive(serde::Serialize)]
        struct Row<'a> {
            id: &'a str,
            title: &'a str,
            subtitle: Option<&'a str>,
            steps: usize,
            last_run: Option<String>,
            modified: Option<String>,
        }
        let rows: Vec<Row> = workflows
            .iter()
            .map(|wf| Row {
                id: &wf.id,
                title: &wf.title,
                subtitle: wf.subtitle.as_deref(),
                steps: wf.steps.len(),
                last_run: wf.last_run.map(|t| t.to_rfc3339()),
                modified: wf.modified.map(|t| t.to_rfc3339()),
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&rows)?);
        return Ok(ExitCode::SUCCESS);
    }

    if workflows.is_empty() {
        println!("no workflows — create one with `wflow run <file.kdl>` or launch the GUI");
        return Ok(ExitCode::SUCCESS);
    }

    // Column widths. Cap id at 36 (UUID len) so long titles still have room.
    let id_w = workflows
        .iter()
        .map(|wf| wf.id.len().min(36))
        .max()
        .unwrap_or(2)
        .max(2);
    let title_w = workflows
        .iter()
        .map(|wf| wf.title.chars().count().min(40))
        .max()
        .unwrap_or(5)
        .max(5);

    println!(
        "{:id_w$}  {:title_w$}  {:>5}  {}",
        "ID",
        "TITLE",
        "STEPS",
        "LAST RUN",
        id_w = id_w,
        title_w = title_w
    );
    for wf in &workflows {
        let title: String = wf.title.chars().take(40).collect();
        let last = wf
            .last_run
            .map(|t| humanize(chrono::Utc::now() - t))
            .unwrap_or_else(|| "never".into());
        println!(
            "{:id_w$}  {:title_w$}  {:>5}  {}",
            truncate(&wf.id, 36),
            title,
            wf.steps.len(),
            last,
            id_w = id_w,
            title_w = title_w
        );
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_validate(target: &str) -> Result<ExitCode> {
    let wf = load_target(target)?;
    let steps = wf.steps.len();
    let steps_word = if steps == 1 { "step" } else { "steps" };
    println!(
        "{} ok — {} {} (schema 1)",
        wf.title, steps, steps_word
    );
    Ok(ExitCode::SUCCESS)
}

fn cmd_show(target: &str) -> Result<ExitCode> {
    let wf = load_target(target)?;
    println!("{}", bold(&wf.title));
    if let Some(sub) = &wf.subtitle {
        if !sub.is_empty() {
            println!("  {}", dim(sub));
        }
    }
    if wf.steps.is_empty() {
        println!("  (no steps)");
        return Ok(ExitCode::SUCCESS);
    }
    let w = (wf.steps.len().ilog10() as usize) + 1;
    for (i, step) in wf.steps.iter().enumerate() {
        let marker = if step.enabled { " " } else { "·" };
        let kind = step.action.category();
        println!(
            "  {:>w$}{} {:<9} {}",
            i + 1,
            marker,
            kind,
            step.action.describe(),
            w = w
        );
        if let Some(note) = &step.note {
            if !note.is_empty() {
                println!("     {:w$}   ↳ {}", "", dim(note), w = w);
            }
        }
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_run(target: &str, dry_run: bool, explain: bool, yes: bool) -> Result<ExitCode> {
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
            // User confirmed — remember the choice for next run.
            security::mark_trusted(&canonical_path, &hash)?;
        }
    }

    // Build a runtime only when we actually need one.
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("tokio runtime")?;

    // The sink receives RunEvents in order from inside run_workflow. We
    // print them as they land so progress is live. `ran` counts StepDone
    // events — the post-flatten number, which may exceed wf.steps.len()
    // when `repeat` blocks expand.
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

// ------------------------------- helpers ------------------------------------

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
        // Highlight shell + clipboard especially — those are the lines
        // most likely to do something the user shouldn't auto-approve.
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

/// Resolve TARGET to a `Workflow`. Tries path first — if it contains a
/// slash, ends in `.kdl`, or exists on disk. Otherwise looks the id up
/// in the library.
fn load_target(target: &str) -> Result<Workflow> {
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
        // KDL path: expand any `include "..."` nodes relative to the
        // including file's directory.
        _ => kdl_format::decode_from_file(p),
    }
}

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
            // Quiet on StepStart — only print the outcome so the line can
            // carry the success/error glyph.
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

/// Walk steps (recursing through `repeat` blocks) and collect the set
/// of external binaries the workflow needs.
fn collect_tool_needs(
    steps: &[crate::actions::Step],
    needed: &mut std::collections::BTreeSet<&'static str>,
) {
    for step in steps {
        if !step.enabled {
            continue;
        }
        match &step.action {
            // Input/window actions go through wdotool-core in-process.
            // They don't need a binary on PATH; their failure mode is
            // "no backend reachable", surfaced at first dispatch.
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
            // `include` / `use` should be expanded by load_file; if one
            // survived here, preflight has nothing to report but should
            // not crash.
            Action::Include { .. } | Action::Use { .. } => {}
            Action::Shell { .. } | Action::Delay { .. } | Action::Note { .. } => {}
        }
    }
}

/// Build the subprocess command line(s) that the engine would invoke for
/// `action`, formatted as one or more shell-quoted strings ready to print.
/// In-process actions (delay, note, await-window, clipboard) come back as
/// a comment-style line so the explain output stays one-row-per-thing.
fn explain_lines(action: &Action) -> Vec<String> {
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
            // Render nested structure so explain output tracks the source
            // shape rather than the engine's flattened iteration stream.
            let mut lines = vec![format!(
                "{head} # repeat {count}× ({} step{})",
                steps.len(),
                if steps.len() == 1 { "" } else { "s" }
            )];
            indent_inner(steps, &mut lines);
            lines
        }
        Action::Conditional { cond, negate, steps } => {
            let verb = if *negate { "unless" } else { "when" };
            let mut lines = vec![format!(
                "{head} # {verb} {} ({} step{})",
                cond.describe(),
                steps.len(),
                if steps.len() == 1 { "" } else { "s" }
            )];
            indent_inner(steps, &mut lines);
            lines
        }
        Action::Include { path } => {
            // Normally expanded away by decode_from_file before explain
            // runs. If one survives, print a single line so the user
            // can tell.
            vec![format!("{head} # include {}", path)]
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

/// POSIX-ish shell quoting. Bare for safe alphanum-ish strings, otherwise
/// single-quoted with embedded single quotes escaped as '\''.
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

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() > max {
        let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
        out.push('…');
        out
    } else {
        s.to_string()
    }
}

fn humanize(d: chrono::Duration) -> String {
    let secs = d.num_seconds();
    if secs < 0 {
        return "just now".into();
    }
    match secs {
        0..=59 => "just now".into(),
        60..=3599 => format!("{}m ago", secs / 60),
        3600..=86_399 => format!("{}h ago", secs / 3600),
        86_400..=1_209_599 => {
            let days = secs / 86_400;
            if days == 1 { "yesterday".into() } else { format!("{days}d ago") }
        }
        _ => format!("{}d ago", secs / 86_400),
    }
}

fn plural_s(n: usize) -> &'static str {
    if n == 1 { "" } else { "s" }
}

// ANSI niceties. Respect NO_COLOR and check isatty on stdout so piped
// output stays clean.
fn ansi_enabled() -> bool {
    use std::io::IsTerminal;
    static CELL: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *CELL.get_or_init(|| {
        if std::env::var_os("NO_COLOR").is_some() {
            return false;
        }
        std::io::stdout().is_terminal()
    })
}

fn wrap(code: &str, s: &str) -> String {
    if ansi_enabled() {
        format!("\x1b[{code}m{s}\x1b[0m")
    } else {
        s.to_string()
    }
}

fn bold(s: &str) -> String { wrap("1", s) }
fn dim(s: &str) -> String { wrap("2", s) }
fn check() -> String { wrap("32", "✓") }     // green
fn cross() -> String { wrap("31", "✗") }     // red
fn dot() -> String   { wrap("33", "·") }     // amber
fn arrow() -> String { wrap("33", "▶") }     // amber
