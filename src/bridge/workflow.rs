//! WorkflowController. The currently-open workflow as JSON, plus the
//! run / debug / trust-prompt machinery the editor binds against.

use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;

use cxx_qt::Threading;
use cxx_qt_lib::QString;

use crate::actions::{RunEvent, StepOutcome, Workflow};
use crate::{engine, kdl_format, security, store};

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
    }

    unsafe extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[qproperty(QString, workflow_json)]
        #[qproperty(i32, active_step)]
        #[qproperty(QString, active_step_id)]
        #[qproperty(bool, running)]
        #[qproperty(bool, paused)]
        #[qproperty(QString, last_error)]
        type WorkflowController = super::WorkflowControllerRust;

        #[qinvokable]
        fn load(self: Pin<&mut WorkflowController>, id: QString);

        /// Wraps a fragment file in a synthetic workflow so the editor
        /// can render it through the same bindings as a real workflow.
        /// Synthetic id: `fragment:<abspath>`. Inner `use` calls are
        /// left unexpanded.
        #[qinvokable]
        fn load_fragment(self: Pin<&mut WorkflowController>, path: QString);

        /// Resolves `imports[name]` to an absolute path, relative to
        /// the current workflow's directory. Empty on any failure.
        #[qinvokable]
        fn resolve_import_path(
            self: Pin<&mut WorkflowController>,
            name: QString,
        ) -> QString;

        /// Returns the id that was written.
        #[qinvokable]
        fn save(self: Pin<&mut WorkflowController>, json: QString) -> QString;

        /// Encode a JSON array of steps as a KDL fragment string.
        /// Strips editor-only `_id`s. "" on bad json.
        #[qinvokable]
        fn steps_to_kdl(self: Pin<&mut WorkflowController>, steps_json: QString) -> QString;

        /// Parse a KDL fragment string into a JSON array of steps.
        /// "" on parse failure (sets `last_error`).
        #[qinvokable]
        fn steps_from_kdl(self: Pin<&mut WorkflowController>, kdl: QString) -> QString;

        /// Encode a full workflow JSON document as canonical KDL
        /// (title + vars + imports + triggers + steps + groups). Strips
        /// editor-only `_id`s so the source matches what hits disk.
        /// Used by the canvas view-source pane.
        #[qinvokable]
        fn workflow_to_kdl(
            self: Pin<&mut WorkflowController>,
            workflow_json: QString,
        ) -> QString;

        /// Encode a step list and write it to the system clipboard
        /// (arboard, wlr-data-control with X11 fallback). Returns true
        /// on success. Lets QML do copy without the hidden-TextEdit
        /// kludge that grabs focus.
        #[qinvokable]
        fn copy_steps_to_clipboard(
            self: Pin<&mut WorkflowController>,
            steps_json: QString,
        ) -> bool;

        /// Read the system clipboard and parse as a KDL fragment.
        /// Returns step JSON on success, "" otherwise.
        #[qinvokable]
        fn paste_steps_from_clipboard(self: Pin<&mut WorkflowController>) -> QString;

        /// Read a `.kdl` file from disk and parse it as a KDL fragment.
        /// Accepts a plain path or a `file://` URL. Returns step JSON
        /// on success, "" otherwise. Used by the canvas's drag-and-drop
        /// import path so a `.kdl` dropped from a file manager lands
        /// in the current workflow the same way a paste does.
        #[qinvokable]
        fn steps_from_kdl_path(self: Pin<&mut WorkflowController>, path: QString) -> QString;

        /// Writes the steps array from the synthetic-workflow JSON back
        /// to the fragment file. Drops id / title / imports etc.
        /// Returns the path on success, "" on failure.
        #[qinvokable]
        fn save_fragment(
            self: Pin<&mut WorkflowController>,
            path: QString,
            json: QString,
        ) -> QString;

        /// Returns immediately. Trusted workflows run; untrusted ones
        /// fire `trust_prompt_required` and wait for confirm/cancel.
        #[qinvokable]
        fn run(self: Pin<&mut WorkflowController>);

        /// Same as `run` but the engine pauses before each step.
        /// Advance with `step_next` / `continue_run` / `stop_run`.
        #[qinvokable]
        fn run_debug(self: Pin<&mut WorkflowController>);

        #[qinvokable]
        fn step_next(self: Pin<&mut WorkflowController>);

        #[qinvokable]
        fn continue_run(self: Pin<&mut WorkflowController>);

        #[qinvokable]
        fn stop_run(self: Pin<&mut WorkflowController>);

        #[qinvokable]
        fn confirm_trust(self: Pin<&mut WorkflowController>);

        #[qinvokable]
        fn cancel_trust(self: Pin<&mut WorkflowController>);

        /// `status` is "ok" | "skipped" | "error". `step_id` is the
        /// stable id (so canvas can paint status on repeat children
        /// that don't have a flat-index card).
        #[qsignal]
        fn step_done(
            self: Pin<&mut WorkflowController>,
            index: i32,
            step_id: QString,
            status: QString,
            message: QString,
        );

        /// Always fires, even when the qproperties dedupe (e.g. a
        /// `repeat` re-entering the same step id), so the inner-step
        /// pulse can restart per iteration.
        #[qsignal]
        fn step_started(
            self: Pin<&mut WorkflowController>,
            index: i32,
            step_id: QString,
        );

        #[qsignal]
        fn run_finished(self: Pin<&mut WorkflowController>, ok: bool);

        /// `summary` is multi-line human text the QML dialog renders
        /// verbatim. The engine waits for confirm_trust / cancel_trust.
        #[qsignal]
        fn trust_prompt_required(
            self: Pin<&mut WorkflowController>,
            summary: QString,
        );
    }

    impl cxx_qt::Threading for WorkflowController {}
}

pub struct WorkflowControllerRust {
    pub workflow_json: QString,
    pub active_step: i32,
    pub active_step_id: QString,
    pub running: bool,
    pub paused: bool,
    pub last_error: QString,
    /// Held between `run()` and `confirm_trust` / `cancel_trust`.
    pending_trust: Option<PendingTrust>,
    pending_debug: bool,
    debug_tx: Option<tokio::sync::mpsc::Sender<engine::DebugCommand>>,
    /// Long-lived clipboard handle. On X11 the process owns the
    /// selection only while a `Clipboard` is alive; opening a fresh
    /// one per copy and dropping it immediately races the clipboard
    /// manager and trips arboard's "request timed out" warning.
    /// Lazy so a clipboard-less env (CI, headless build) doesn't
    /// fail to construct the controller.
    clipboard: Option<arboard::Clipboard>,
}

struct PendingTrust {
    path: PathBuf,
    hash: String,
    workflow: Workflow,
}

impl Default for WorkflowControllerRust {
    fn default() -> Self {
        Self {
            workflow_json: QString::from(""),
            active_step: -1,
            active_step_id: QString::from(""),
            running: false,
            paused: false,
            last_error: QString::from(""),
            pending_trust: None,
            pending_debug: false,
            debug_tx: None,
            clipboard: None,
        }
    }
}

impl qobject::WorkflowController {
    fn load(mut self: Pin<&mut Self>, id: QString) {
        let id_s: String = id.to_string();
        // Authored form so `use NAME` cards survive the round-trip;
        // run() expands them before handing the workflow to the engine.
        match store::load_authored(&id_s) {
            Ok(wf) => {
                let json = serde_json::to_string(&wf).unwrap_or_else(|_| "{}".into());
                self.as_mut().set_workflow_json(QString::from(&json));
                self.as_mut().set_active_step(-1);
                self.as_mut().set_last_error(QString::from(""));
            }
            Err(e) => {
                tracing::warn!(?e, "load {}", id_s);
                self.as_mut().set_last_error(QString::from(&format!("{e:#}")));
            }
        }
    }

    fn load_fragment(mut self: Pin<&mut Self>, path: QString) {
        let path_s: String = path.to_string();
        let p = std::path::Path::new(&path_s);
        match kdl_format::decode_fragment_file(p) {
            Ok(steps) => {
                let title = p
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("fragment")
                    .to_string();
                let mut wf = Workflow::new(title);
                wf.id = format!("fragment:{}", p.to_string_lossy());
                wf.steps = steps;
                let json = serde_json::to_string(&wf).unwrap_or_else(|_| "{}".into());
                self.as_mut().set_workflow_json(QString::from(&json));
                self.as_mut().set_active_step(-1);
                self.as_mut().set_last_error(QString::from(""));
            }
            Err(e) => {
                tracing::warn!(?e, "load_fragment {}", path_s);
                self.as_mut()
                    .set_last_error(QString::from(&format!("{e:#}")));
            }
        }
    }

    fn save_fragment(
        mut self: Pin<&mut Self>,
        path: QString,
        json: QString,
    ) -> QString {
        let path_s: String = path.to_string();
        if path_s.is_empty() {
            self.as_mut()
                .set_last_error(QString::from("save_fragment: empty path"));
            return QString::from("");
        }
        let text: String = json.to_string();
        let wf: Workflow = match serde_json::from_str(&text) {
            Ok(wf) => wf,
            Err(e) => {
                tracing::warn!(?e, "save_fragment: bad json");
                self.as_mut()
                    .set_last_error(QString::from(&format!("bad json: {e}")));
                return QString::from("");
            }
        };
        // Steps only; the fragment file has no workflow wrapper.
        let body = kdl_format::encode_fragment(&wf.steps);
        let p = std::path::Path::new(&path_s);
        // tmp + rename so a crash mid-write doesn't truncate.
        let tmp = p.with_extension("kdl.tmp");
        if let Some(parent) = p.parent() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                tracing::warn!(?e, "save_fragment: mkdir parent");
                self.as_mut()
                    .set_last_error(QString::from(&format!("mkdir parent: {e}")));
                return QString::from("");
            }
        }
        if let Err(e) = std::fs::write(&tmp, body.as_bytes()) {
            tracing::warn!(?e, "save_fragment: write tmp");
            self.as_mut()
                .set_last_error(QString::from(&format!("write {}: {e}", tmp.display())));
            return QString::from("");
        }
        if let Err(e) = std::fs::rename(&tmp, p) {
            tracing::warn!(?e, "save_fragment: rename");
            self.as_mut()
                .set_last_error(QString::from(&format!(
                    "rename {} -> {}: {e}",
                    tmp.display(),
                    p.display()
                )));
            return QString::from("");
        }
        // Re-emit so the editor's bindings stay live.
        let rewrap = serde_json::to_string(&wf).unwrap_or_else(|_| "{}".into());
        self.as_mut().set_workflow_json(QString::from(&rewrap));
        self.as_mut().set_last_error(QString::from(""));
        QString::from(&path_s)
    }

    fn resolve_import_path(
        mut self: Pin<&mut Self>,
        name: QString,
    ) -> QString {
        let name_s: String = name.to_string();
        let json: String = self.workflow_json.to_string();
        let wf: Workflow = match serde_json::from_str(&json) {
            Ok(wf) => wf,
            Err(_) => return QString::from(""),
        };
        // Fragment pages base off the fragment file's parent.
        let base_dir = if let Some(stripped) = wf.id.strip_prefix("fragment:") {
            std::path::Path::new(stripped)
                .parent()
                .map(|p| p.to_path_buf())
                .unwrap_or_default()
        } else {
            match store::path_of(&wf.id) {
                Ok(p) => p.parent().map(|p| p.to_path_buf()).unwrap_or_default(),
                Err(e) => {
                    tracing::warn!(?e, "resolve_import_path: workflow has no on-disk path");
                    return QString::from("");
                }
            }
        };
        let path_str = match wf.imports.get(&name_s) {
            Some(p) => p.clone(),
            None => return QString::from(""),
        };
        match kdl_format::resolve_import_path(&path_str, &base_dir) {
            Ok(p) => QString::from(&p.to_string_lossy().to_string()),
            Err(e) => {
                tracing::warn!(?e, "resolve_import_path failed");
                self.as_mut()
                    .set_last_error(QString::from(&format!("{e:#}")));
                QString::from("")
            }
        }
    }

    fn save(mut self: Pin<&mut Self>, json: QString) -> QString {
        let text: String = json.to_string();
        let wf: Workflow = match serde_json::from_str(&text) {
            Ok(wf) => wf,
            Err(e) => {
                tracing::warn!(?e, "save: bad json");
                self.as_mut().set_last_error(QString::from(&format!("bad json: {e}")));
                return QString::from("");
            }
        };
        match store::save(wf) {
            Ok(saved) => {
                let rewrap = serde_json::to_string(&saved).unwrap_or_else(|_| "{}".into());
                self.as_mut().set_workflow_json(QString::from(&rewrap));
                QString::from(&saved.id)
            }
            Err(e) => {
                tracing::warn!(?e, "save failed");
                self.as_mut().set_last_error(QString::from(&format!("{e:#}")));
                QString::from("")
            }
        }
    }

    fn steps_to_kdl(mut self: Pin<&mut Self>, steps_json: QString) -> QString {
        let text: String = steps_json.to_string();
        let mut steps: Vec<crate::actions::Step> = match serde_json::from_str(&text) {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(?e, "steps_to_kdl: bad json");
                self.as_mut()
                    .set_last_error(QString::from(&format!("copy as kdl: bad steps json: {e}")));
                return QString::from("");
            }
        };
        // _id keys into the per-workflow positions sidecar; meaningless
        // outside this editor's local state, and noise in a snippet
        // shared via chat / a README.
        for step in &mut steps {
            strip_editor_ids(step);
        }
        let body = kdl_format::encode_fragment(&steps);
        self.as_mut().set_last_error(QString::from(""));
        QString::from(&body)
    }

    fn workflow_to_kdl(mut self: Pin<&mut Self>, workflow_json: QString) -> QString {
        let text: String = workflow_json.to_string();
        let mut wf: Workflow = match serde_json::from_str(&text) {
            Ok(wf) => wf,
            Err(e) => {
                tracing::warn!(?e, "workflow_to_kdl: bad json");
                self.as_mut()
                    .set_last_error(QString::from(&format!("view source: bad json: {e}")));
                return QString::from("");
            }
        };
        for step in &mut wf.steps {
            strip_editor_ids(step);
        }
        let body = kdl_format::encode(&wf);
        self.as_mut().set_last_error(QString::from(""));
        QString::from(&body)
    }

    fn steps_from_kdl(mut self: Pin<&mut Self>, kdl: QString) -> QString {
        let text: String = kdl.to_string();
        match kdl_format::decode_fragment_str(&text) {
            Ok(steps) => {
                let json = serde_json::to_string(&steps).unwrap_or_else(|_| "[]".into());
                self.as_mut().set_last_error(QString::from(""));
                QString::from(&json)
            }
            Err(e) => {
                tracing::warn!(?e, "steps_from_kdl: parse failed");
                self.as_mut()
                    .set_last_error(QString::from(&format!("paste kdl: {e:#}")));
                QString::from("")
            }
        }
    }

    fn copy_steps_to_clipboard(mut self: Pin<&mut Self>, steps_json: QString) -> bool {
        use cxx_qt::CxxQtType;
        let kdl = self.as_mut().steps_to_kdl(steps_json);
        let text: String = kdl.to_string();
        if text.is_empty() {
            return false;
        }
        let result = clipboard_handle(self.as_mut().rust_mut().get_mut())
            .and_then(|cb| cb.set_text(text).map_err(anyhow::Error::from));
        match result {
            Ok(()) => {
                self.as_mut().set_last_error(QString::from(""));
                true
            }
            Err(e) => {
                tracing::warn!(?e, "copy_steps_to_clipboard failed");
                self.as_mut()
                    .set_last_error(QString::from(&format!("copy as kdl: {e:#}")));
                false
            }
        }
    }

    fn paste_steps_from_clipboard(mut self: Pin<&mut Self>) -> QString {
        use cxx_qt::CxxQtType;
        let text_result: anyhow::Result<String> =
            clipboard_handle(self.as_mut().rust_mut().get_mut()).and_then(|cb| {
                match cb.get_text() {
                    Ok(s) => Ok(s),
                    Err(arboard::Error::ContentNotAvailable) => Ok(String::new()),
                    Err(e) => Err(anyhow::Error::from(e)),
                }
            });
        let text = match text_result {
            Ok(t) => t,
            Err(e) => {
                tracing::warn!(?e, "paste_steps_from_clipboard failed");
                self.as_mut()
                    .set_last_error(QString::from(&format!("paste kdl: {e:#}")));
                return QString::from("");
            }
        };
        if text.trim().is_empty() {
            return QString::from("");
        }
        self.as_mut().steps_from_kdl(QString::from(&text))
    }

    fn steps_from_kdl_path(mut self: Pin<&mut Self>, path: QString) -> QString {
        let raw: String = path.to_string();
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            self.as_mut()
                .set_last_error(QString::from("import kdl: empty path"));
            return QString::from("");
        }
        // Caller (QML DropArea) is expected to hand over a plain path,
        // not a `file://` URL. URL-to-path decoding lives in the QML
        // side so we don't have to drag a percent-decoder into the
        // bridge for one use.
        let text = match std::fs::read_to_string(trimmed) {
            Ok(t) => t,
            Err(e) => {
                tracing::warn!(?e, path = %trimmed, "steps_from_kdl_path: read failed");
                self.as_mut()
                    .set_last_error(QString::from(&format!("import kdl: {e}")));
                return QString::from("");
            }
        };
        if text.trim().is_empty() {
            return QString::from("");
        }
        self.as_mut().steps_from_kdl(QString::from(&text))
    }

    fn run(mut self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;

        if self.running {
            return;
        }
        let text: String = self.workflow_json.to_string();
        let mut wf: Workflow = match serde_json::from_str(&text) {
            Ok(wf) => wf,
            Err(e) => {
                tracing::warn!(?e, "run: bad workflow_json");
                self.as_mut().set_last_error(QString::from(&format!("bad json: {e}")));
                return;
            }
        };

        // path_of failing = unsaved workflow. Run without a trust check.
        let path = match store::path_of(&wf.id) {
            Ok(p) => Some(p),
            Err(_) => None,
        };

        // Editor preserves the authored form; the engine wants `use`
        // calls inlined. Unsaved workflows can still resolve absolute
        // import paths.
        if let Some(p) = path.as_ref() {
            if let Err(e) = kdl_format::expand_imports_in_place(&mut wf, p) {
                tracing::warn!(?e, "expand_imports failed");
                self.as_mut().set_last_error(QString::from(&format!("{e:#}")));
                return;
            }
        } else if !wf.imports.is_empty() {
            if let Err(e) = kdl_format::expand_imports_in_place(
                &mut wf,
                std::path::Path::new(""),
            ) {
                tracing::warn!(?e, "expand_imports failed (unsaved)");
                self.as_mut().set_last_error(QString::from(&format!("{e:#}")));
                return;
            }
        }

        let debug = self.as_ref().rust().pending_debug;
        match path {
            Some(p) => match security::check_trust(&p, security::TrustMode::Gui) {
                Ok(security::TrustDecision::Trusted) => {
                    self.as_mut().rust_mut().pending_debug = false;
                    if debug {
                        self.as_mut()._start_engine_debug(wf);
                    } else {
                        self.as_mut()._start_engine(wf);
                    }
                }
                Ok(security::TrustDecision::Untrusted { canonical_path, hash }) => {
                    let summary = build_trust_summary(&wf);
                    self.as_mut().rust_mut().pending_trust = Some(PendingTrust {
                        path: canonical_path,
                        hash,
                        workflow: wf,
                    });
                    self.as_mut().trust_prompt_required(QString::from(&summary));
                }
                Err(e) => {
                    tracing::warn!(?e, "trust check failed");
                    self.as_mut().rust_mut().pending_debug = false;
                    self.as_mut().set_last_error(QString::from(&format!("{e:#}")));
                }
            },
            None => {
                self.as_mut().rust_mut().pending_debug = false;
                if debug {
                    self.as_mut()._start_engine_debug(wf);
                } else {
                    self.as_mut()._start_engine(wf);
                }
            }
        }
    }

    fn confirm_trust(mut self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;

        let pending = self.as_mut().rust_mut().pending_trust.take();
        let pt = match pending {
            Some(pt) => pt,
            None => return, // nothing to confirm
        };
        if let Err(e) = security::mark_trusted(&pt.path, &pt.hash) {
            // Don't block the run; worst case the next run re-prompts.
            tracing::warn!(?e, "mark_trusted after confirm");
        }
        let debug = self.as_ref().rust().pending_debug;
        self.as_mut().rust_mut().pending_debug = false;
        if debug {
            self.as_mut()._start_engine_debug(pt.workflow);
        } else {
            self.as_mut()._start_engine(pt.workflow);
        }
    }

    fn run_debug(mut self: Pin<&mut Self>) {
        // Reuse run()'s trust path; pending_debug picks the entry point.
        use cxx_qt::CxxQtType;
        self.as_mut().rust_mut().pending_debug = true;
        self.as_mut().run();
    }

    fn step_next(self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        if let Some(tx) = self.as_ref().rust().debug_tx.clone() {
            // try_send so we never block the Qt thread.
            let _ = tx.try_send(engine::DebugCommand::Step);
        }
    }

    fn continue_run(self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        if let Some(tx) = self.as_ref().rust().debug_tx.clone() {
            let _ = tx.try_send(engine::DebugCommand::Continue);
        }
    }

    fn stop_run(self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        if let Some(tx) = self.as_ref().rust().debug_tx.clone() {
            let _ = tx.try_send(engine::DebugCommand::Stop);
        }
    }

    fn cancel_trust(mut self: Pin<&mut Self>) {
        use cxx_qt::CxxQtType;
        self.as_mut().rust_mut().pending_trust = None;
    }

    fn _start_engine(mut self: Pin<&mut Self>, wf: Workflow) {
        self.as_mut().set_running(true);
        self.as_mut().set_paused(false);
        self.as_mut().set_active_step(-1);
        self.as_mut().set_last_error(QString::from(""));

        let sink = self.as_mut()._build_sink();

        let wf_id = wf.id.clone();
        tokio::spawn(async move {
            if let Err(e) = engine::run_workflow(sink, wf).await {
                tracing::warn!(?e, "run_workflow failed");
            }
            // `touch_last_run` on a best-effort basis, the Finished event
            // has already fired from inside run_workflow.
            store::touch_last_run(&wf_id);
        });
    }

    /// _start_engine variant under PauseControl::on, with a command
    /// channel for step_next / continue_run / stop_run.
    fn _start_engine_debug(mut self: Pin<&mut Self>, wf: Workflow) {
        use cxx_qt::CxxQtType;
        self.as_mut().set_running(true);
        self.as_mut().set_paused(false);
        self.as_mut().set_active_step(-1);
        self.as_mut().set_last_error(QString::from(""));

        let (tx, rx) = tokio::sync::mpsc::channel::<engine::DebugCommand>(4);
        self.as_mut().rust_mut().debug_tx = Some(tx);

        let sink = self.as_mut()._build_sink();

        let wf_id = wf.id.clone();
        let pause = engine::PauseControl::on(rx);
        tokio::spawn(async move {
            if let Err(e) = engine::run_workflow_with(sink, wf, pause).await {
                tracing::warn!(?e, "run_workflow_with failed");
            }
            store::touch_last_run(&wf_id);
        });
    }

    fn _build_sink(self: Pin<&mut Self>) -> engine::EventSink {
        let qt_thread = self.qt_thread();
        Arc::new(move |ev: RunEvent| {
            let thread = qt_thread.clone();
            let _ = thread.queue(move |mut ctrl: Pin<&mut qobject::WorkflowController>| {
                use cxx_qt::CxxQtType;
                match ev {
                    RunEvent::Started { .. } => {}
                    RunEvent::StepStart { index, step_id } => {
                        ctrl.as_mut().set_paused(false);
                        ctrl.as_mut().set_active_step(index as i32);
                        ctrl.as_mut().set_active_step_id(QString::from(&step_id));
                        ctrl.as_mut().step_started(
                            index as i32,
                            QString::from(&step_id),
                        );
                    }
                    RunEvent::StepDone {
                        index, step_id, outcome, ..
                    } => {
                        let (status, message) = match &outcome {
                            StepOutcome::Ok { output, .. } => (
                                "ok",
                                output.clone().unwrap_or_default(),
                            ),
                            StepOutcome::Skipped { reason } => ("skipped", reason.clone()),
                            StepOutcome::Error { message, .. } => ("error", message.clone()),
                        };
                        ctrl.as_mut().step_done(
                            index as i32,
                            QString::from(&step_id),
                            QString::from(status),
                            QString::from(&message),
                        );
                        if matches!(outcome, StepOutcome::Error { .. }) {
                            ctrl.as_mut().set_last_error(QString::from(&message));
                        }
                    }
                    RunEvent::Paused { index } => {
                        ctrl.as_mut().set_paused(true);
                        ctrl.as_mut().set_active_step(index as i32);
                    }
                    RunEvent::Finished { ok, .. } => {
                        ctrl.as_mut().set_running(false);
                        ctrl.as_mut().set_paused(false);
                        ctrl.as_mut().set_active_step(-1);
                        ctrl.as_mut().set_active_step_id(QString::from(""));
                        ctrl.as_mut().rust_mut().debug_tx = None;
                        ctrl.as_mut().run_finished(ok);
                    }
                }
            });
        })
    }
}

#[cfg(test)]
mod strip_ids_tests {
    use super::strip_editor_ids;
    use crate::actions::{Action, Condition, Step};

    #[test]
    fn clears_top_and_nested_ids() {
        let mut s = Step {
            id: "top-id".into(),
            enabled: true,
            on_error: Default::default(),
            note: None,
            action: Action::Conditional {
                cond: Condition::Window { name: "Firefox".into() },
                negate: false,
                steps: vec![Step {
                    id: "yes-id".into(),
                    enabled: true,
                    on_error: Default::default(),
                    note: None,
                    action: Action::Note { text: "in yes".into() },
                }],
                else_steps: vec![Step {
                    id: "no-id".into(),
                    enabled: true,
                    on_error: Default::default(),
                    note: None,
                    action: Action::Repeat {
                        count: 2,
                        steps: vec![Step {
                            id: "deep-id".into(),
                            enabled: true,
                            on_error: Default::default(),
                            note: None,
                            action: Action::Note { text: "deep".into() },
                        }],
                    },
                }],
            },
        };
        strip_editor_ids(&mut s);
        assert!(s.id.is_empty());
        if let Action::Conditional { steps, else_steps, .. } = &s.action {
            assert!(steps[0].id.is_empty());
            assert!(else_steps[0].id.is_empty());
            if let Action::Repeat { steps: inner, .. } = &else_steps[0].action {
                assert!(inner[0].id.is_empty());
            } else {
                panic!("expected Repeat in else");
            }
        } else {
            panic!("expected Conditional");
        }
    }
}

#[cfg(test)]
mod workflow_to_kdl_tests {
    use crate::actions::Workflow;
    use crate::kdl_format;

    #[test]
    fn json_round_trip_encodes_back_to_runnable_kdl() {
        let src = r#"workflow "test" {
    subtitle "view-source round trip"
    vars {
        repo "/tmp/repo"
    }
    trigger {
        chord "ctrl+alt+t"
    }
    note "kickoff"
    type "echo hi"
    key "Return"
    shell "git status"
}
"#;
        let parsed = kdl_format::decode(src).expect("decode sample");
        let json = serde_json::to_string(&parsed).expect("serialize to json");
        let from_json: Workflow = serde_json::from_str(&json).expect("deserialize from json");
        let encoded = kdl_format::encode(&from_json);
        let reparsed = kdl_format::decode(&encoded).expect("decode re-encoded");
        assert_eq!(parsed.title, reparsed.title);
        assert_eq!(parsed.steps.len(), reparsed.steps.len());
        assert_eq!(parsed.triggers.len(), reparsed.triggers.len());
    }

}

/// Lazy accessor for the controller's persistent `arboard::Clipboard`.
/// On X11 the Clipboard owns the selection, so dropping it between
/// calls hands ownership back before a clipboard manager has a chance
/// to mirror the contents (the symptom is arboard's "request timed
/// out" warning). Holding one for the controller's lifetime fixes it
/// without needing the SetLinuxExt/wait dance.
fn clipboard_handle(rust: &mut WorkflowControllerRust) -> anyhow::Result<&mut arboard::Clipboard> {
    use anyhow::Context;
    if rust.clipboard.is_none() {
        rust.clipboard =
            Some(arboard::Clipboard::new().context("open system clipboard")?);
    }
    Ok(rust.clipboard.as_mut().unwrap())
}

/// Recursively clear `step.id` so a clipboard/snippet copy carries no
/// editor-local state. Inner steps of `repeat` and `when`/`unless` get
/// the same treatment.
fn strip_editor_ids(step: &mut crate::actions::Step) {
    use crate::actions::Action;
    step.id.clear();
    match &mut step.action {
        Action::Repeat { steps, .. } => {
            for s in steps {
                strip_editor_ids(s);
            }
        }
        Action::Conditional { steps, else_steps, .. } => {
            for s in steps {
                strip_editor_ids(s);
            }
            for s in else_steps {
                strip_editor_ids(s);
            }
        }
        _ => {}
    }
}

/// Multi-line summary for the trust prompt. Matches `cli::cmd_run`.
fn build_trust_summary(wf: &Workflow) -> String {
    let mut out = String::new();
    out.push_str("This workflow will:\n");
    let mut shown = 0usize;
    for step in &wf.steps {
        if !step.enabled {
            continue;
        }
        let kind = step.action.category();
        let marker = match kind {
            "shell" | "clipboard" => "•",
            _ => "·",
        };
        out.push_str(&format!(
            "  {marker} {kind:<9} {desc}\n",
            desc = step.action.describe()
        ));
        shown += 1;
        if shown >= 12 && wf.steps.len() > 12 {
            out.push_str(&format!(
                "  · ... and {} more\n",
                wf.steps.len() - shown
            ));
            break;
        }
    }
    out
}
