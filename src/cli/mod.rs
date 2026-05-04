//! Command-line interface.
//!
//! When `wflow` is invoked with a subcommand (`run`, `list`, `validate`,
//! `show`, `path`, ...), we dispatch here and never bring up Qt. Plain
//! `wflow` with no arguments still launches the GUI from `main`.
//!
//! The CLI is split by concern. Each topic module owns the cmd_*
//! handlers for its area; this file owns the Cli enum, the run()
//! dispatcher, and shared text/output helpers.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use clap_complete::Shell;

mod daemon;
mod inspect;
mod lifecycle;
mod run;
mod system;

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

    /// Deep-link target. The Linux `wflow://` URL handler routes here:
    /// the registered .desktop file passes the URL as a positional
    /// argument, this argument captures it without a subcommand, and
    /// the GUI launches with the import dialog ready to fire.
    ///
    /// Hidden from help so it doesn't pollute `wflow --help`; the
    /// integration is documented in the .desktop file we ship.
    #[arg(hide = true)]
    pub deeplink: Option<String>,
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
    /// Run the trigger daemon: bind every chord declared in your
    /// library to the configured workflow, dispatch on activation,
    /// reload when workflow files change. Single instance per user.
    /// Uses the GlobalShortcuts portal on KDE Plasma 6 and GNOME 46+;
    /// falls back to compositor IPC on Hyprland and Sway. Ctrl+C
    /// unbinds everything cleanly.
    Daemon,
    /// Internal: invoked by the trigger daemon's compositor binds.
    /// Loads the workflow, checks `trigger.when` against the focused
    /// window, and runs the workflow if the predicate holds (or no
    /// predicate is set). Exits 0 silently when the predicate fails
    /// so the chord registers as a no-op rather than a noisy error.
    /// Not meant for direct CLI use — `wflow run` is the public path.
    #[command(hide = true)]
    TriggerFire {
        /// Library id of the workflow to fire.
        target: String,
    },
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
        Command::Run { target, dry_run, explain, yes } => {
            run::cmd_run(&target, dry_run, explain, yes)
        }
        Command::List { json } => inspect::cmd_list(json),
        Command::Validate { target } => inspect::cmd_validate(&target),
        Command::Show { target } => inspect::cmd_show(&target),
        Command::Path => inspect::cmd_path(),
        Command::Ids => inspect::cmd_ids(),
        Command::Edit { target } => lifecycle::cmd_edit(&target),
        Command::Rm { target, force } => lifecycle::cmd_rm(&target, force),
        Command::New { title, stdout } => lifecycle::cmd_new(&title, stdout),
        Command::Migrate { dry_run } => lifecycle::cmd_migrate(dry_run),
        Command::Doctor => system::cmd_doctor(),
        Command::Completions { shell } => system::cmd_completions(shell),
        Command::Man { output } => system::cmd_man(output.as_deref()),
        Command::Daemon => daemon::cmd_daemon(),
        Command::TriggerFire { target } => run::cmd_trigger_fire(&target),
    };

    match result {
        Ok(code) => code,
        Err(e) => {
            eprintln!("error: {e:#}");
            ExitCode::from(1)
        }
    }
}

// ─────────────────────────────── shared helpers ──────────────────────────────

/// Look up a binary on PATH.
pub(super) fn which(bin: &str) -> Option<PathBuf> {
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
/// `flatpak-spawn --host -- which <bin>` so doctor / preflight report
/// what the engine will actually see at run time. Outside a sandbox
/// this is a plain `which`.
pub(super) fn which_host(bin: &str) -> Option<PathBuf> {
    if !crate::host::in_flatpak() {
        return which(bin);
    }
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

pub(super) fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() > max {
        let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
        out.push('…');
        out
    } else {
        s.to_string()
    }
}

pub(super) fn humanize(d: chrono::Duration) -> String {
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

pub(super) fn plural_s(n: usize) -> &'static str {
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

pub(super) fn wrap(code: &str, s: &str) -> String {
    if ansi_enabled() {
        format!("\x1b[{code}m{s}\x1b[0m")
    } else {
        s.to_string()
    }
}

pub(super) fn bold(s: &str) -> String { wrap("1", s) }
pub(super) fn dim(s: &str) -> String { wrap("2", s) }
pub(super) fn check() -> String { wrap("32", "✓") }
pub(super) fn cross() -> String { wrap("31", "✗") }
pub(super) fn dot() -> String { wrap("33", "·") }
pub(super) fn arrow() -> String { wrap("33", "▶") }
