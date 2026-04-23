//! RecorderController — Record Mode state machine.
//!
//! Minimal first pass.

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "RustQt" {
        #[qobject]
        #[qml_element]
        type RecorderController = super::RecorderControllerRust;
    }
}

#[derive(Default)]
pub struct RecorderControllerRust;
