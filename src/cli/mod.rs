//! CLI entry. `wflow <subcommand>` dispatches here without bringing up
//! Qt; `wflow` alone still launches the GUI from `main`. Topic modules
//! own their cmd_* handlers; this file is the enum, dispatcher, and
//! the shared output helpers (color, humanize, plural_s).

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
    long_about = "wflow executes KDL workflow files, sequences of keystrokes, clicks, shell commands, delays, and notifications. Input/window actions go through the in-process wdotool-core engine; shell, notify-send, and wl-copy still subprocess to the host. \
Run `wflow` with no arguments to launch the GUI."
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Command>,

    /// Captures the `wflow://` URL when our .desktop file routes a
    /// deep-link click here. Hidden from --help; .desktop file
    /// documents the contract.
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
    /// Convert legacy-format workflow files to the current format in
    /// place. Files migrate lazily on next save anyway; this is the
    /// one-shot version. Pass `--dry-run` to preview without writing.
    Migrate {
        /// Print the conversion plan without rewriting any files.
        #[arg(long)]
        dry_run: bool,
    },
    /// Generate the wflow(1) man page (and one page per subcommand).
    /// No flags: top-level page to stdout. `--output DIR` writes
    /// per-subcommand pages (wflow-run.1, wflow-list.1, ...) — what
    /// packagers want.
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
    /// Internal: the daemon's compositor binds exec this. Gates on
    /// `trigger.when` against the focused window before running.
    /// `wflow run` is the public path; this is hidden from --help.
    #[command(hide = true)]
    TriggerFire {
        /// Library id of the workflow to fire.
        target: String,
    },
}

pub fn run(cli: Cli) -> ExitCode {
    // Quiet by default. Users opt in via RUST_LOG.
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

/// `which` that probes the host PATH via flatpak-spawn when sandboxed,
/// so doctor reports what the engine actually sees at runtime.
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

// ANSI helpers. Respects NO_COLOR + isatty so piped output stays clean.
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
