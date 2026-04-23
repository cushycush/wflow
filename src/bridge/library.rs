//! LibraryController — the patch library surface exposed to QML.
//!
//! Minimal first pass: just a pingable QObject so the build pipeline can
//! register a QML element. Real properties and invokables land in the
//! next pass.

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "RustQt" {
        #[qobject]
        #[qml_element]
        type LibraryController = super::LibraryControllerRust;
    }
}

#[derive(Default)]
pub struct LibraryControllerRust;
