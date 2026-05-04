//! wflow — Qt Quick front-end + CLI over the Rust engine.
//!
//! `wflow` with no subcommand launches the GUI (QQmlApplicationEngine
//! loads the Wflow QML module). Everything else (`run`, `list`,
//! `validate`, `show`, `path`) is routed through `cli.rs` and never
//! brings up Qt.

mod actions;
mod active_window;
mod bridge;
mod cli;
mod daemon_autostart;
mod daemon_lock;
mod engine;
mod gui_lock;
mod host;
mod kdl_format;
mod recorder;
mod scheme_handler;
mod security;
mod state;
mod store;
mod templates;
mod triggers;
mod wdo;
mod workflows_meta;

use std::process::ExitCode;

use clap::Parser;
use cxx_qt_lib::{QGuiApplication, QQmlApplicationEngine, QUrl};

fn main() -> ExitCode {
    let parsed = cli::Cli::parse();
    if parsed.command.is_some() {
        return cli::run(parsed);
    }
    run_gui(parsed.deeplink.clone())
}

fn run_gui(deeplink: Option<String>) -> ExitCode {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("wflow=info,warn")),
        )
        .try_init();

    // Single-instance lock + URL forwarding socket. xdg-open spawns a
    // fresh wflow process for every wflow:// URL it routes; the
    // pidfile check turns those forwarding launches into "send the
    // URL to the running instance, exit." If we're the first
    // instance, bind the socket and keep the receiver alive for the
    // duration of the GUI.
    let lock_outcome = match gui_lock::try_acquire() {
        Ok(o) => o,
        Err(e) => {
            eprintln!("wflow: couldn't acquire single-instance lock: {e:#}");
            // Fail open — without the lock the worst case is we run
            // a second window (today's behaviour). Better than
            // refusing to start.
            return run_gui_with_lock(None, deeplink);
        }
    };

    match lock_outcome {
        gui_lock::AcquireOutcome::Acquired(guard, url_rx) => {
            // Hand the receiver to the bridge layer; DeeplinkInbox's
            // start invokable will pull it out once QML constructs
            // the singleton.
            bridge::deeplink_inbox::install_url_receiver(url_rx);
            // First-run side-effects on the lock-holder path. Both
            // are idempotent across launches via state.toml flags
            // and skip on Flatpak (sandbox can't reach host
            // systemd / user applications dir).
            daemon_autostart::ensure_enabled();
            // Install the wflow:// URL scheme handler so the
            // browser's redirect after sign-in actually reaches the
            // running app. Without this, source / cargo installs
            // get sign-in flows that complete in the browser but
            // never deliver the callback URL — the app stays in
            // "Signing in…" forever.
            scheme_handler::ensure_installed();
            run_gui_with_lock(Some(guard), deeplink)
        }
        gui_lock::AcquireOutcome::AlreadyRunning { pid } => {
            // Another wflow GUI is up. Forward the deeplink we were
            // launched with (if any) and exit clean. If we had no
            // URL to forward, the user just double-launched the
            // app — print a friendly note and exit.
            if let Some(url) = deeplink {
                if let Err(e) = gui_lock::forward_url(&url) {
                    eprintln!(
                        "wflow: couldn't hand the URL to the running instance (pid {pid}): {e:#}"
                    );
                    return ExitCode::FAILURE;
                }
                tracing::info!("forwarded deeplink to wflow gui pid {pid}");
            } else {
                eprintln!("wflow is already running (pid {pid})");
            }
            ExitCode::SUCCESS
        }
    }
}

fn run_gui_with_lock(
    _guard: Option<gui_lock::LockGuard>,
    deeplink: Option<String>,
) -> ExitCode {
    // Tokio runtime owned by the app — bridge controllers spawn their
    // async work on this. Enter a guard so top-level spawn() works.
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    let _runtime_guard = runtime.enter();

    // Stash any cold-start deeplink for the QML layer to pick up via
    // ExploreController.take_pending_deeplink on first paint. Hot-
    // launch deeplinks (forwarded from a second wflow process)
    // arrive via DeeplinkInbox.url_received instead.
    if let Some(url) = deeplink {
        std::env::set_var("WFLOW_PENDING_DEEPLINK", url);
    }

    let mut app = QGuiApplication::new();
    let mut engine = QQmlApplicationEngine::new();

    if let Some(engine) = engine.as_mut() {
        engine.load(&QUrl::from("qrc:/qt/qml/Wflow/qml/Main.qml"));
    }

    if let Some(app) = app.as_mut() {
        app.exec();
    }
    // _guard drops here, unlinking the pidfile + socket.
    ExitCode::SUCCESS
}
