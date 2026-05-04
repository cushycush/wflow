//! `wflow` with no subcommand launches the GUI; everything else
//! routes through `cli/` and never brings up Qt.

mod actions;
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

    // xdg-open spawns a fresh wflow per wflow:// URL; the pidfile
    // turns those into "forward the URL, exit". Fail-open if the
    // lock can't bind: a second window beats refusing to start.
    let lock_outcome = match gui_lock::try_acquire() {
        Ok(o) => o,
        Err(e) => {
            eprintln!("wflow: couldn't acquire single-instance lock: {e:#}");
            return run_gui_with_lock(None, deeplink);
        }
    };

    match lock_outcome {
        gui_lock::AcquireOutcome::Acquired(guard, url_rx) => {
            bridge::deeplink_inbox::install_url_receiver(url_rx);
            // First-run side-effects. Both are state.toml-gated.
            daemon_autostart::ensure_enabled();
            scheme_handler::ensure_installed();
            run_gui_with_lock(Some(guard), deeplink)
        }
        gui_lock::AcquireOutcome::AlreadyRunning { pid } => {
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
    // Bridge controllers spawn async work on this runtime.
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    let _runtime_guard = runtime.enter();

    // Cold-start deeplink. Hot-launch ones come through DeeplinkInbox.
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
    ExitCode::SUCCESS
}
