//! wflow — Qt Quick front-end, Rust engine.
//!
//! `fn main` boots QGuiApplication, instantiates a QQmlApplicationEngine,
//! and loads the Wflow QML module's root `Main.qml`. Bridge QObjects are
//! auto-registered by cxx-qt when their modules are linked in below.

mod actions;
mod bridge;
mod engine;
mod kdl_format;
mod recorder;
mod store;

use cxx_qt_lib::{QGuiApplication, QQmlApplicationEngine, QUrl};

fn main() {
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
}
