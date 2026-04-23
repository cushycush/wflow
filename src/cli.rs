//! Command-line interface.
//!
//! When `wflow` is invoked with a subcommand (`run`, `list`, `validate`,
//! `show`, `path`), we dispatch here and never bring up Qt. Plain
//! `wflow` with no arguments still launches the GUI from `main`.

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use clap::{Parser, Subcommand};

use crate::actions::{Action, RunEvent, StepOutcome, Workflow};
use crate::{engine, kdl_format, store};

#[derive(Parser, Debug)]
#[command(
    name = "wflow",
    version,
    about = "A workflow engine for Wayland automation.",
    long_about = "wflow executes KDL workflow files — sequences of keystrokes, clicks, shell commands, delays, and notifications — via wdotool and the system shell. \
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
        Command::Run { target, dry_run } => cmd_run(&target, dry_run),
        Command::List { json } => cmd_list(json),
        Command::Validate { target } => cmd_validate(&target),
        Command::Show { target } => cmd_show(&target),
        Command::Path => cmd_path(),
        Command::New { title, stdout } => cmd_new(&title, stdout),
        Command::Doctor => cmd_doctor(),
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
    // fresh workflow is a no-op until the user turns them on.
    let wf = Workflow::new(title);
    let created = wf
        .created
        .map(|t| t.to_rfc3339())
        .unwrap_or_else(|| chrono::Utc::now().to_rfc3339());
    let template = format!(
        "// A wflow workflow. See `docs/KDL.md` for the full action vocabulary.\n\
         schema 1\n\
         id \"{id}\"\n\
         title \"{title}\"\n\
         created \"{created}\"\n\
         modified \"{created}\"\n\
         \n\
         recipe {{\n    \
             // Starter steps — marked `disabled=#true` so `wflow run` is a no-op\n    \
             // until you turn them on. Delete these lines and write your own.\n    \
             notify \"hello from wflow\" disabled=#true\n    \
             shell \"echo 'wflow ran at ' \\\"$(date)\\\"\" disabled=#true\n    \
             await-window \"Firefox\" timeout=\"5s\" disabled=#true\n    \
             key \"ctrl+l\" disabled=#true\n\
         }}\n",
        id = wf.id,
        title = title.replace('"', "\\\""),
        created = created,
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

fn cmd_doctor() -> Result<ExitCode> {
    // Tools wflow invokes as subprocesses. Not all workflows need all of
    // them — wflow itself doesn't fail to launch on a missing notify-send.
    // This is a preflight so the user knows what the current environment
    // will support.
    let tools: &[(&str, &str)] = &[
        ("wdotool", "keyboard / mouse / focus automation"),
        ("notify-send", "desktop notifications"),
        ("wl-copy", "clipboard (Wayland)"),
    ];

    let mut all_ok = true;
    let path_w = tools.iter().map(|(n, _)| n.len()).max().unwrap_or(0).max(8);
    for (bin, role) in tools {
        match which(bin) {
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
                    dim("(not on PATH)"),
                    dim(role),
                    path_w = path_w
                );
            }
        }
    }

    // Workflow directory / count summary.
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

fn cmd_run(target: &str, dry_run: bool) -> Result<ExitCode> {
    let wf = load_target(target)?;

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

    // Build a runtime only when we actually need one.
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("tokio runtime")?;

    // The sink receives RunEvents in order from inside run_workflow. We
    // print them as they land so progress is live.
    let step_count = wf.steps.len();
    let title = wf.title.clone();
    let failed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let failed_c = failed.clone();

    let sink: engine::EventSink = Arc::new(move |ev| print_event(&title, step_count, &failed_c, ev));

    runtime.block_on(async move { engine::run_workflow(sink, wf).await })?;

    if failed.load(std::sync::atomic::Ordering::SeqCst) {
        return Ok(ExitCode::from(2));
    }
    Ok(ExitCode::SUCCESS)
}

// ------------------------------- helpers ------------------------------------

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
    let text = std::fs::read_to_string(p).with_context(|| format!("read {}", p.display()))?;
    match p.extension().and_then(|s| s.to_str()) {
        Some("json") => serde_json::from_str(&text)
            .with_context(|| format!("parse json {}", p.display())),
        _ => kdl_format::decode(&text).with_context(|| format!("parse kdl {}", p.display())),
    }
}

fn print_event(title: &str, step_count: usize, failed: &Arc<std::sync::atomic::AtomicBool>, ev: RunEvent) {
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
            if ok {
                println!("{} finished ({} step{})", check(), step_count, plural_s(step_count));
            } else {
                println!("{} failed", cross());
            }
        }
    }
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
