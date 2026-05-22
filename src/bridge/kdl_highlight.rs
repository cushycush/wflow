//! Tiny bridge for the KDL syntax highlighter's QML type registration.
//! No QObject of its own — the highlighter is a pure-C++ class
//! (`cpp/kdl_syntax_highlighter.h`). All this does is expose the
//! `register_kdl_qml_types` C++ helper to Rust so `main.rs` can call
//! it before `QQmlApplicationEngine::load`.

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("kdl_qml_register.h");

        #[rust_name = "register_kdl_qml_types"]
        fn register_kdl_qml_types();
    }
}
