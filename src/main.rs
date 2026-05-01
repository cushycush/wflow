//! wflow — Qt Quick front-end + CLI over the Rust engine.
//!
//! `wflow` with no subcommand launches the GUI (QQmlApplicationEngine
//! loads the Wflow QML module). Everything else (`run`, `list`,
//! `validate`, `show`, `path`) is routed through `cli.rs` and never
//! brings up Qt.

mod actions;
mod bridge;
mod cli;
mod daemon_lock;
mod engine;
mod host;
mod kdl_format;
mod recorder;
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
    // Deep-link entry point: a `wflow://import?source=<url>` URL handed
    // off by xdg-open lands here as the only positional arg. Stash it
    // for the QML layer to pick up via ExploreController once the GUI
    // has finished booting (no point opening the import dialog before
    // the user even sees the window).
    if let Some(deeplink) = parsed.deeplink.as_deref() {
        std::env::set_var("WFLOW_PENDING_DEEPLINK", deeplink);
    }
    run_gui()
}

fn run_gui() -> ExitCode {
    // Tokio runtime owned by the app — bridge controllers spawn their
    // async work on this. Enter a guard so top-level spawn() works.
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    let _guard = runtime.enter();

    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("wflow=info,warn")),
        )
        .try_init();

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
