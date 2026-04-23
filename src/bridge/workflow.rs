//! WorkflowController — the currently-open workflow.
//!
//! Minimal first pass. Real load/save/run lands when the QML UI is settled.

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "RustQt" {
        #[qobject]
        #[qml_element]
        type WorkflowController = super::WorkflowControllerRust;
    }
}

#[derive(Default)]
pub struct WorkflowControllerRust;
