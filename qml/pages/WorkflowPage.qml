import QtQuick
import QtQuick.Controls
import Wflow

// Workflow editor.
//
// Data flows through WorkflowController: we load(id) on mount, decode the
// returned JSON for the title / steps, and call run() to fire the real
// engine on the Rust side. Step progress streams back via the
// active_step property and step_done / run_finished signals.
//
// Edits to a step's primary value (value TextField in SplitInspector) bubble
// back up via `valueEdited(stepIndex, newPrimary)`. We patch the local
// `workflow` object, debounce-save through `wfCtrl.save(JSON)` (~600ms after
// the last keystroke), and show a small "saving / saved" indicator in the
// top bar.
Item {
    id: root
    property string workflowId: ""
    signal backRequested()

    WorkflowController { id: wfCtrl }
    // Owns the blank-workflow tutorial dismissal flag (and the
    // future tutorials map). Shared across pages but always reads
    // state.toml on construction, so per-page instantiation is safe.
    StateController { id: stateCtrl }
    // Per-page LibraryController instance is fine — store::delete is
    // a filesystem op, no shared state to race on. Used by the
    // editor's Delete-workflow flow.
    LibraryController { id: libCtrl }

    // Decoded workflow object. Kept as a local property so the editor can
    // present placeholder text before load() returns AND so in-flight edits
    // have a live target to mutate.
    property var workflow: ({
        id: "",
        title: "Untitled workflow",
        subtitle: "",
        steps: []
    })

    // Save state lifecycle: "idle" → "dirty" (user edited) → "saving" →
    // "saved" (briefly, then back to idle) or "error" on save failure.
    property string saveState: "idle"

    // Per-step outcomes from the last run — { [stepIndex]: "ok"|"skipped"|"error" }.
    // Populated by the bridge's step_done signal; cleared when a new run starts.
    property var stepStatuses: ({})

    // Pending trust-prompt body. Populated when wfCtrl emits
    // `trust_prompt_required(summary)`; trustDialog reads it.
    property string trustSummary: ""

    // True while the blank-workflow tutorial is being shown. Once the
    // user dismisses (or auto-dismiss fires), we don't re-show it
    // even if the user undoes/clears all steps in the same session.
    // The disk flag (state.toml `tutorials.blank_workflow_seen`) is
    // the long-term memory; this is just session pacing.
    property bool _tutorialDismissedThisSession: false
    readonly property bool _shouldShowBlankTutorial:
        root.workflowId.length > 0
        && (root.workflow.steps || []).length === 0
        && !root._tutorialDismissedThisSession
        && !stateCtrl.tutorial_seen("blank_workflow")

    readonly property string title:    workflow.title || "Untitled workflow"
    readonly property string subtitle: workflow.subtitle || ""
    readonly property int activeStepIndex: wfCtrl.active_step
    readonly property bool running: wfCtrl.running
    readonly property var actions: {
        // Shape the Rust-side Step[] into the { kind, summary, value, rawPrimary, editable }
        // that the split-inspector delegates expect.
        const out = []
        const steps = root.workflow.steps || []
        for (const s of steps) {
            out.push(root._stepToAction(s))
        }
        return out
    }

    function _stepToAction(step) {
        const act = step.action || {}
        const kind = act.kind || "note"
        let shaped
        switch (kind) {
        case "wdo_type":            shaped = { kind: "type",     summary: "Type text",         value: act.text,                              rawPrimary: act.text,        editable: true }; break
        case "wdo_key":             shaped = { kind: "key",      summary: "Press key chord",   value: act.chord,                             rawPrimary: act.chord,       editable: true }; break
        case "wdo_key_down":        shaped = { kind: "key",      summary: "Hold key",          value: act.chord,                             rawPrimary: act.chord,       editable: true }; break
        case "wdo_key_up":          shaped = { kind: "key",      summary: "Release key",       value: act.chord,                             rawPrimary: act.chord,       editable: true }; break
        case "wdo_click":           shaped = { kind: "click",    summary: "Mouse click",       value: "button " + act.button,                rawPrimary: String(act.button), editable: true, intOnly: true }; break
        case "wdo_mouse_down":      shaped = { kind: "click",    summary: "Hold button",       value: "button " + act.button,                rawPrimary: String(act.button), editable: true, intOnly: true }; break
        case "wdo_mouse_up":        shaped = { kind: "click",    summary: "Release button",    value: "button " + act.button,                rawPrimary: String(act.button), editable: true, intOnly: true }; break
        case "wdo_mouse_move":      shaped = { kind: "move",     summary: "Move cursor",       value: "(" + act.x + ", " + act.y + ")",      rawPrimary: act.x + ", " + act.y, editable: false }; break
        case "wdo_scroll":          shaped = { kind: "scroll",   summary: "Scroll",            value: "dx " + act.dx + " dy " + act.dy,      rawPrimary: act.dx + ", " + act.dy, editable: false }; break
        case "wdo_activate_window": shaped = { kind: "focus",    summary: "Focus window",      value: act.name,                              rawPrimary: act.name,        editable: true }; break
        case "wdo_await_window":    shaped = { kind: "wait",     summary: "Wait for window",   value: act.name,                              rawPrimary: act.name,        editable: true }; break
        case "delay":               shaped = { kind: "wait",     summary: "Wait",              value: act.ms + " ms",                        rawPrimary: String(act.ms),  editable: true, intOnly: true, unit: "ms" }; break
        case "shell":               shaped = { kind: "shell",    summary: "Run shell command", value: act.command,                           rawPrimary: act.command,     editable: true }; break
        case "notify":              shaped = { kind: "notify",   summary: "Notify",            value: act.title,                             rawPrimary: act.title,       editable: true }; break
        case "clipboard":           shaped = { kind: "clipboard",summary: "Copy to clipboard", value: act.text,                              rawPrimary: act.text,        editable: true }; break
        case "note":                shaped = { kind: "note",     summary: "Note",              value: act.text,                              rawPrimary: act.text,        editable: true }; break
        // Flow-control actions — read-only in the GUI for now. They round-trip through the KDL file but edit via $EDITOR.
        case "repeat":              shaped = { kind: "wait",     summary: "Repeat " + act.count + "×", value: (act.steps || []).length + " inner step(s)", rawPrimary: "", editable: false }; break
        case "conditional":         shaped = { kind: "wait",     summary: (act.negate ? "Unless" : "When"), value: _condSummary(act.cond),                 rawPrimary: "", editable: false }; break
        case "include":             shaped = { kind: "shell",    summary: "Include",           value: act.path,                              rawPrimary: act.path,        editable: true }; break
        case "use":                 shaped = { kind: "shell",    summary: "Use import",        value: act.name,                              rawPrimary: act.name,        editable: true }; break
        default:                    shaped = { kind: "note", summary: kind, value: "", rawPrimary: "", editable: false }
        }
        // Expose the raw Step + Action so the inspector can bind option editors
        // (disabled, on-error, delay-ms, clear-modifiers, retries, backoff-ms,
        // timeout-ms) directly to their canonical fields.
        shaped.id = step.id || ""
        shaped.rawKind = kind
        shaped.enabled = step.enabled !== false
        shaped.onError = step.on_error || "stop"
        shaped.rawAction = act
        return shaped
    }

    function _condSummary(cond) {
        if (!cond) return ""
        switch (cond.kind) {
        case "window": return "window = " + (cond.name || "")
        case "file":   return "file = "   + (cond.path || "")
        case "env":    return "env."      + (cond.name || "") + (cond.equals ? " = " + cond.equals : "")
        }
        return ""
    }

    // Return a clone of `oldAction` with its primary value replaced.
    // Kind-aware so a `delay` step turns "500" into {ms: 500} rather than
    // shoving a string into the ms field. Non-mutable kinds pass the old
    // action through unchanged.
    function _mutateAction(oldAction, newPrimary) {
        const out = JSON.parse(JSON.stringify(oldAction))
        const kind = out.kind
        switch (kind) {
        case "wdo_type":            out.text    = newPrimary; break
        case "wdo_key":
        case "wdo_key_down":
        case "wdo_key_up":          out.chord   = newPrimary; break
        case "wdo_click":
        case "wdo_mouse_down":
        case "wdo_mouse_up":        {
            const n = parseInt(newPrimary, 10)
            if (isNaN(n) || n < 0) return oldAction
            out.button = n; break
        }
        case "wdo_activate_window":
        case "wdo_await_window":    out.name    = newPrimary; break
        case "delay": {
            const n = parseInt(newPrimary, 10)
            if (isNaN(n) || n < 0) return oldAction
            out.ms = n; break
        }
        case "shell":               out.command = newPrimary; break
        case "notify":              out.title   = newPrimary; break
        case "clipboard":           out.text    = newPrimary; break
        case "note":                out.text    = newPrimary; break
        case "include":             out.path    = newPrimary; break
        case "use":                 out.name    = newPrimary; break
        default: return oldAction
        }
        return out
    }

    // Apply a per-step option edit. `path` is one of:
    //   "enabled"           — bool
    //   "on_error"          — "stop" | "continue"
    //   "action.<field>"    — kind-specific action field (delay_ms,
    //                         clear_modifiers, retries, backoff_ms, timeout_ms)
    // A null / empty value on an Option<T> action field deletes the key so
    // the serde default kicks in on round-trip.
    function _commitOption(stepIndex, path, value) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = wf.steps || []
        if (stepIndex < 0 || stepIndex >= steps.length) return
        const step = steps[stepIndex]
        if (path === "enabled") {
            if (step.enabled === value) return
            step.enabled = value
        } else if (path === "on_error") {
            if ((step.on_error || "stop") === value) return
            step.on_error = value
        } else if (path.startsWith("action.")) {
            const key = path.slice(7)
            if (!step.action) return
            const isEmpty = value === null || value === undefined || value === ""
            if (isEmpty) {
                if (!(key in step.action)) return
                delete step.action[key]
            } else {
                if (step.action[key] === value) return
                step.action[key] = value
            }
        } else {
            return
        }
        wf.steps = steps
        root.workflow = wf
        _scheduleSave()
    }

    function _uuid() {
        // RFC-4122 v4-ish; good enough for a local step id. The Rust side
        // doesn't validate UUID shape, only that `id` is a unique string.
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
            const r = Math.random() * 16 | 0
            const v = c === 'x' ? r : (r & 0x3 | 0x8)
            return v.toString(16)
        })
    }

    function _defaultActionForKind(kind) {
        switch (kind) {
        case "key":       return { kind: "wdo_key",             chord: "Return" }
        case "type":      return { kind: "wdo_type",            text:  "hello" }
        case "click":     return { kind: "wdo_click",           button: 1 }
        case "move":      return { kind: "wdo_mouse_move",      x: 0, y: 0, relative: false }
        case "scroll":    return { kind: "wdo_scroll",          dx: 0, dy: 0 }
        case "focus":     return { kind: "wdo_activate_window", name: "firefox" }
        case "wait":      return { kind: "delay",               ms: 500 }
        case "shell":     return { kind: "shell",               command: "echo hello" }
        case "notify":    return { kind: "notify",              title: "Done" }
        case "clipboard": return { kind: "clipboard",           text: "" }
        case "note":      return { kind: "note",                text: "" }
        }
        return { kind: "note", text: "" }
    }

    function _addStep(kind) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = wf.steps || []
        const id = _uuid()
        steps.push({
            id: id,
            enabled: true,
            on_error: "stop",
            action: _defaultActionForKind(kind)
        })
        wf.steps = steps
        root.workflow = wf
        editorContent.selectedIndex = steps.length - 1
        _scheduleSave()
        return id
    }

    // Add a step from a palette drop. Like _addStep but seeds the
    // canvas's positions map so the new card lands where the user
    // dropped it, AND clears the auto-selection so the inspector
    // doesn't slide in and shove the canvas around mid-drop.
    //
    // Position is written BEFORE the workflow mutation. Otherwise
    // _placeNewSteps fires synchronously on the actions-changed
    // signal, sees no entry for the new id, and assigns it a
    // stack-below position; the user's drop coordinate then
    // overwrites that and the cardItem animates away from origin
    // and back to the drop spot.
    function _addStepAt(kind, x, y) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = wf.steps || []
        const id = _uuid()
        steps.push({
            id: id,
            enabled: true,
            on_error: "stop",
            action: _defaultActionForKind(kind)
        })
        wf.steps = steps
        // Pre-seed the position so _placeNewSteps skips this id.
        const next = Object.assign({}, canvasView.positions)
        next[id] = { x: Math.max(0, x), y: Math.max(0, y) }
        canvasView.positions = next
        // Intentionally NO selectedIndex change — the user dropped
        // the card to place it, not to immediately edit it.
        root.workflow = wf
        _scheduleSave()
    }

    function _deleteStep(stepIndex) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = wf.steps || []
        if (stepIndex < 0 || stepIndex >= steps.length) return
        steps.splice(stepIndex, 1)
        wf.steps = steps
        root.workflow = wf
        // Keep selection valid: clamp into range, or collapse the
        // inspector when no steps remain.
        if (steps.length === 0) {
            editorContent.selectedIndex = -1
        } else if (editorContent.selectedIndex >= steps.length) {
            editorContent.selectedIndex = steps.length - 1
        }
        _scheduleSave()
    }

    // Make the step at otherIdx the immediate predecessor of the
    // step at stepIdx. Used by both the inspector's prev/next swap
    // and the canvas's per-card rewire menu, so it takes the target
    // index explicitly rather than reading editorContent.selectedIndex.
    function _makePredecessorOf(stepIdx, otherIdx) {
        if (stepIdx < 0 || otherIdx < 0 || otherIdx === stepIdx) return
        const target = otherIdx < stepIdx ? stepIdx - 1 : stepIdx
        _moveStep(otherIdx, target)
    }

    function _makeSuccessorOf(stepIdx, otherIdx) {
        if (stepIdx < 0 || otherIdx < 0 || otherIdx === stepIdx) return
        const target = otherIdx > stepIdx ? stepIdx + 1 : stepIdx
        _moveStep(otherIdx, target)
    }

    function _moveStep(from, to) {
        if (from === to) return
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = wf.steps || []
        if (from < 0 || from >= steps.length) return
        if (to < 0 || to >= steps.length) return
        const [moved] = steps.splice(from, 1)
        steps.splice(to, 0, moved)
        wf.steps = steps
        root.workflow = wf
        // Follow the moved step so the inspector keeps looking at
        // the same action the user just reordered.
        const sel = editorContent.selectedIndex
        if (sel === from) {
            editorContent.selectedIndex = to
        } else if (from < sel && to >= sel) {
            editorContent.selectedIndex = sel - 1
        } else if (from > sel && to <= sel) {
            editorContent.selectedIndex = sel + 1
        }
        _scheduleSave()
    }

    function _commitStepEdit(stepIndex, newPrimary) {
        // Clone the whole workflow so the QML binding system notices the
        // change; mutating a nested array in place doesn't always trigger.
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = wf.steps || []
        if (stepIndex < 0 || stepIndex >= steps.length) return
        const oldAction = steps[stepIndex].action || {}
        const newAction = _mutateAction(oldAction, newPrimary)
        // Noop when the helper rejected the edit (invalid int, etc).
        if (JSON.stringify(newAction) === JSON.stringify(oldAction)) return
        steps[stepIndex].action = newAction
        wf.steps = steps
        root.workflow = wf
        _scheduleSave()
    }

    function _commitTitleEdit(newTitle) {
        if (newTitle === root.workflow.title) return
        const wf = JSON.parse(JSON.stringify(root.workflow))
        wf.title = newTitle
        root.workflow = wf
        _scheduleSave()
    }

    function _commitSubtitleEdit(newSubtitle) {
        if (newSubtitle === (root.workflow.subtitle || "")) return
        const wf = JSON.parse(JSON.stringify(root.workflow))
        wf.subtitle = newSubtitle
        root.workflow = wf
        _scheduleSave()
    }

    function _scheduleSave() {
        root.saveState = "dirty"
        saveTimer.restart()
    }

    function _askDelete() {
        // No-op for new-draft workflows that haven't been saved yet:
        // there's nothing on disk to delete; just navigate back.
        if (!root.workflowId || root.workflowId === "new-draft") {
            root.backRequested()
            return
        }
        deleteDialog.open()
    }

    WfConfirmDialog {
        id: deleteDialog
        title: "Delete workflow?"
        message: "This permanently deletes “" + (root.title || "Untitled workflow")
            + "” from your library. The KDL file is removed from disk."
        confirmText: "Delete"
        destructive: true
        onConfirmed: {
            libCtrl.remove(root.workflowId)
            root.backRequested()
        }
    }

    function _saveNow() {
        root.saveState = "saving"
        const json = JSON.stringify(root.workflow)
        const newId = wfCtrl.save(json)
        if (newId && newId.length > 0) {
            root.saveState = "saved"
            savedToast.restart()
        } else {
            root.saveState = "error"
        }
    }

    Timer { id: saveTimer; interval: 600; repeat: false; onTriggered: root._saveNow() }
    Timer { id: savedToast; interval: 1800; repeat: false
        onTriggered: if (root.saveState === "saved") root.saveState = "idle"
    }

    // ============ Card-position persistence ============
    // Canvas card positions persist via the workflows.toml sidecar
    // (same file that already holds last_run timestamps). Keyed by
    // (workflowId, stepId). Save fires on canvas positions-change
    // (debounced 400ms); load runs after each workflow_jsonChanged.

    function _loadPositions() {
        if (!root.workflowId || root.workflowId.length === 0) return
        let parsed = {}
        try {
            parsed = JSON.parse(libCtrl.load_positions(root.workflowId) || "{}")
        } catch (e) {
            return
        }
        if (parsed && Object.keys(parsed).length > 0) {
            // Merge saved positions over the canvas's default
            // placements. Without the merge, cards without a saved
            // entry would lose their default position too, ending up
            // at (0, 0) — which also wipes wires whose source or
            // target lookup misses.
            const merged = Object.assign({}, canvasView.positions, parsed)
            canvasView.positions = merged
        }
    }

    // Silent resave so the .kdl file picks up `_id` properties for
    // every step. Bypasses _saveNow so saveState / the saved-toast
    // don't fire — this is a load-time upgrade, not a user save.
    function _ensureStableIds() {
        if (!root.workflowId || root.workflowId.length === 0) return
        const steps = (root.workflow && root.workflow.steps) || []
        if (steps.length === 0) return
        wfCtrl.save(JSON.stringify(root.workflow))
    }

    function _savePositions() {
        if (!root.workflowId || root.workflowId.length === 0) return
        const positions = canvasView.positions || {}
        libCtrl.save_positions(root.workflowId, JSON.stringify(positions))
    }

    Timer { id: positionsSaveTimer; interval: 400; repeat: false
        onTriggered: root._savePositions()
    }

    Connections {
        target: canvasView
        function onPositionsChanged() {
            if (root.workflowId && root.workflowId.length > 0) {
                positionsSaveTimer.restart()
            }
        }
    }

    onWorkflowIdChanged: _reload()
    Component.onCompleted: _reload()

    // Run on Ctrl+Enter — the editor is the only page where this is active,
    // and the enabled guard matches the Run button.
    Shortcut {
        sequence: "Ctrl+Return"
        enabled: root.visible && (root.actions || []).length > 0 && !root.running
        onActivated: wfCtrl.run()
    }

    // Save explicitly on Ctrl+S (in case the user likes the shortcut). Still
    // debounce-saves automatically.
    Shortcut {
        sequence: "Ctrl+S"
        enabled: root.visible && root.saveState !== "idle"
        onActivated: { saveTimer.stop(); root._saveNow() }
    }

    function _reload() {
        if (!root.workflowId) {
            root.workflow = { id: "", title: "Untitled workflow", subtitle: "", steps: [] }
            root.saveState = "idle"
            return
        }
        wfCtrl.load(root.workflowId)
    }

    Connections {
        target: wfCtrl
        function onWorkflow_jsonChanged() {
            try {
                root.workflow = JSON.parse(wfCtrl.workflow_json || "{}")
            } catch (e) {
                root.workflow = { id: "", title: "Untitled workflow", subtitle: "", steps: [] }
            }
            // One-shot silent upgrade: write the .kdl back so the
            // file has _id properties for every step. Loading a
            // workflow whose .kdl predates the _id feature gives
            // each step a fresh UUID via Step::new() — saving
            // positions against those UUIDs would lose them on the
            // next decode. The re-save makes the IDs round-trip.
            Qt.callLater(root._ensureStableIds)
            // Restore saved card positions for this workflow. Deferred
            // via Qt.callLater so the canvas's _placeNewSteps has run
            // and seeded defaults — _loadPositions then overwrites
            // them where a saved entry exists.
            Qt.callLater(root._loadPositions)
        }
        function onRunningChanged() {
            // Clear previous statuses at the start of a fresh run so stale
            // glyphs from the last run don't bleed into the new one.
            if (wfCtrl.running) root.stepStatuses = ({})
        }
        function onStep_done(index, status, message) {
            const next = Object.assign({}, root.stepStatuses)
            next[index] = status
            root.stepStatuses = next
        }
        function onTrust_prompt_required(summary) {
            root.trustSummary = summary
            trustDialog.open()
        }
    }

    Column {
        anchors.fill: parent
        spacing: 0

        TopBar {
            id: tb
            width: parent.width
            title: root.title
            subtitle: root.subtitle
            titleEditable: true
            subtitleEditable: true
            backVisible: true
            onBackClicked: root.backRequested()
            onTitleCommitted: (t) => root._commitTitleEdit(t)
            onSubtitleCommitted: (t) => root._commitSubtitleEdit(t)

            // Compact save-state indicator to the left of the action buttons.
            Text {
                visible: root.saveState !== "idle"
                anchors.verticalCenter: parent.verticalCenter
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontXs
                font.weight: Font.Medium
                text: {
                    switch (root.saveState) {
                    case "dirty":  return "● unsaved"
                    case "saving": return "● saving…"
                    case "saved":  return "✓ saved"
                    case "error":  return "✗ save failed"
                    }
                    return ""
                }
                color: {
                    switch (root.saveState) {
                    case "dirty":  return Theme.text3
                    case "saving": return Theme.accent
                    case "saved":  return Theme.ok
                    case "error":  return Theme.err
                    }
                    return Theme.text3
                }
            }

            // Direct Delete button. Was a kebab → Delete two-click
            // pattern but for the only entry we have it's friction;
            // when there's a second editor-level action it can move
            // back into a menu.
            SecondaryButton {
                // Stick to a thin Unicode glyph instead of the 🗑
                // emoji — emoji glyphs render at full color-glyph
                // height and made the Delete button visibly taller
                // than its peers.
                text: "× Delete"
                onClicked: root._askDelete()
            }
            SecondaryButton {
                text: "↗ Share"
            }
            PrimaryButton {
                id: runBtn
                text: root.running ? "⏸ Running…" : "▶ Run"
                leftPadding: 18
                rightPadding: 18
                enabled: (root.actions || []).length > 0 && !root.running
                onClicked: wfCtrl.run()
            }
        }

        // Error banner — surface the last run / save error from the engine.
        Rectangle {
            width: parent.width
            height: visible ? 36 : 0
            visible: wfCtrl.last_error.length > 0
            color: Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.15)
            border.color: Theme.err
            border.width: 1

            Row {
                anchors.fill: parent
                anchors.leftMargin: 24
                anchors.rightMargin: 24
                spacing: 10
                Text {
                    text: "● " + wfCtrl.last_error
                    color: Theme.err
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    width: parent.width - 80
                }
            }
        }

        Item {
            id: editorContent
            width: parent.width
            height: parent.height - tb.height

            // -1 means "no step selected" → inspector slides out and
            // the canvas takes the full width. Auto-selects step 0
            // when a workflow with steps loads.
            property int selectedIndex: -1
            readonly property bool inspectorOpen: selectedIndex >= 0

            // The selected step's shaped action — what the inspector
            // panel binds to.
            readonly property var selectedAction:
                (selectedIndex >= 0 && selectedIndex < (root.actions || []).length)
                    ? root.actions[selectedIndex] : null
            readonly property var prevAction:
                (selectedIndex > 0 && (root.actions || []).length > 0)
                    ? root.actions[selectedIndex - 1] : null
            readonly property var nextAction:
                (selectedIndex >= 0 && selectedIndex + 1 < (root.actions || []).length)
                    ? root.actions[selectedIndex + 1] : null

            // Keep selectedIndex valid as the action list changes; do
            // NOT auto-select when it's -1. Auto-selecting was popping
            // the inspector open every time a step landed from a
            // palette drop — combined with the deselect TapHandler
            // firing in the same release, you'd see the menu flash
            // in / out / in. The user opens the inspector by clicking
            // a card; reconcile only clamps when needed.
            function _reconcileSelection() {
                const n = (root.actions || []).length
                if (n === 0) {
                    selectedIndex = -1
                } else if (selectedIndex >= n) {
                    selectedIndex = n - 1
                }
            }
            Connections {
                target: root
                function onActionsChanged() { editorContent._reconcileSelection() }
            }
            Component.onCompleted: _reconcileSelection()

            EmptyState {
                anchors.fill: parent
                visible: !root.workflowId
                title: "No workflow loaded"
                description: "Pick one from the library, or create a new one."
                actionLabel: ""
            }

            // ---- Three-pane layout: rail | canvas | (slide-in) inspector ----
            StepListRail {
                id: rail
                visible: root.workflowId.length > 0
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.leftMargin: 24
                anchors.topMargin: 16
                anchors.bottomMargin: 24
                width: 280

                actions: root.actions
                activeStepIndex: root.activeStepIndex
                selectedIndex: editorContent.selectedIndex
                stepStatuses: root.stepStatuses

                showTutorial: _shouldShowBlankTutorial
                onTutorialDismissed: {
                    stateCtrl.mark_tutorial_seen("blank_workflow")
                    root._tutorialDismissedThisSession = true
                }

                onSelectRequested: (i) => { editorContent.selectedIndex = i }
                onAddStepRequested: (kind) => {
                    root._addStep(kind)
                    editorContent.selectedIndex = (root.actions || []).length - 1
                }
                onDeleteStepRequested: (stepIndex) => root._deleteStep(stepIndex)
                onMoveStepRequested: (from, to) => root._moveStep(from, to)
            }

            // Inspector container — animates width from 0 → 360 so
            // the slide-in feels driven by the panel's own arrival
            // rather than a separate translation. Canvas anchors to
            // this container's left edge, so it reflows in sync.
            Item {
                id: inspectorContainer
                visible: root.workflowId.length > 0
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.rightMargin: 24
                anchors.topMargin: 16
                anchors.bottomMargin: 24
                width: editorContent.inspectorOpen ? 360 : 0
                clip: true
                Behavior on width {
                    NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Theme.easingStd }
                }

                StepInspectorPanel {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 360
                    sel: editorContent.selectedAction
                    selectedIndex: editorContent.selectedIndex
                    totalSteps: (root.actions || []).length
                    prevAction: editorContent.prevAction
                    nextAction: editorContent.nextAction
                    allActions: root.actions
                    onValueEdited: (stepIndex, newPrimary) => root._commitStepEdit(stepIndex, newPrimary)
                    onOptionEdited: (stepIndex, path, value) => root._commitOption(stepIndex, path, value)
                    onCloseRequested: { editorContent.selectedIndex = -1 }
                    onSelectStep: (i) => { editorContent.selectedIndex = i }
                    onPredecessorChosen: (otherIdx) => root._makePredecessorOf(editorContent.selectedIndex, otherIdx)
                    onSuccessorChosen: (otherIdx) => root._makeSuccessorOf(editorContent.selectedIndex, otherIdx)
                }
            }

            WorkflowCanvas {
                id: canvasView
                visible: root.workflowId.length > 0
                anchors.left: rail.right
                anchors.right: inspectorContainer.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.leftMargin: 16
                anchors.rightMargin: editorContent.inspectorOpen ? 16 : 0
                anchors.topMargin: 16
                anchors.bottomMargin: 24
                actions: root.actions
                selectedIndex: editorContent.selectedIndex
                stepStatuses: root.stepStatuses
                onSelectStep: (i) => { editorContent.selectedIndex = i }
                onDeselectRequested: { editorContent.selectedIndex = -1 }
                onAddStepAtRequested: (kind, x, y) => root._addStepAt(kind, x, y)
                onPredecessorChosen: (stepIdx, otherIdx) => root._makePredecessorOf(stepIdx, otherIdx)
                onSuccessorChosen: (stepIdx, otherIdx) => root._makeSuccessorOf(stepIdx, otherIdx)
            }

            // Floating step palette. Drag a chip onto the canvas to
            // add a step at the drop point — palette uses the canvas
            // ref to drive an in-canvas card-shaped preview ghost.
            StepPalette {
                visible: root.workflowId.length > 0
                anchors.bottom: canvasView.bottom
                anchors.horizontalCenter: canvasView.horizontalCenter
                anchors.bottomMargin: 18
                z: 60
                canvas: canvasView
            }
        }
    }

    // Trust prompt for workflows wflow didn't author here. Shown
    // when wfCtrl emits trust_prompt_required; the engine waits for
    // confirm_trust() or cancel_trust() before doing anything.
    // Mirrors the CLI prompt's body (see src/security.rs +
    // src/cli.rs::confirm_untrusted_workflow) and the threat-model
    // pointer in REVIEW.md.
    Dialog {
        id: trustDialog
        parent: Overlay.overlay
        modal: true
        closePolicy: Popup.NoAutoClose
        title: ""

        width: Math.min(640, parent ? parent.width * 0.9 : 640)
        height: Math.min(560, parent ? parent.height * 0.85 : 560)
        anchors.centerIn: parent

        background: Rectangle {
            color: Theme.surface
            radius: Theme.radiusMd
            border.color: Theme.line
            border.width: 1
        }

        contentItem: Item {
            anchors.fill: parent

            Column {
                anchors.fill: parent
                anchors.margins: 24
                spacing: 16

                // Header
                Column {
                    width: parent.width
                    spacing: 6

                    Row {
                        spacing: 10
                        // Warning glyph in accent-warm so it reads as
                        // "stop and look" without alarming red.
                        Rectangle {
                            width: 28; height: 28; radius: 14
                            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                            border.color: Theme.accent
                            border.width: 1
                            anchors.verticalCenter: parent.verticalCenter
                            Text {
                                anchors.centerIn: parent
                                text: "!"
                                color: Theme.accent
                                font.family: Theme.familyBody
                                font.pixelSize: 16
                                font.weight: Font.Bold
                            }
                        }
                        Text {
                            text: "Run this workflow?"
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontXl
                            font.weight: Font.DemiBold
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Text {
                        text: "This workflow file hasn't run on this machine before. Review what it will execute before confirming. (See REVIEW.md for the trust model.)"
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                        width: parent.width
                        lineHeight: 1.4
                    }
                }

                // Step summary — scrollable in case the workflow has
                // more than ~12 enabled steps.
                ScrollView {
                    width: parent.width
                    height: parent.height
                          - parent.spacing * 2
                          - 80   // header
                          - 56   // footer
                    clip: true

                    Text {
                        text: root.trustSummary
                        color: Theme.text2
                        font.family: Theme.familyMono
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.NoWrap
                        textFormat: Text.PlainText
                    }
                }

                // Footer
                Row {
                    width: parent.width
                    spacing: 8
                    layoutDirection: Qt.RightToLeft

                    PrimaryButton {
                        text: "Confirm and run"
                        onClicked: {
                            trustDialog.close()
                            wfCtrl.confirm_trust()
                        }
                    }
                    SecondaryButton {
                        text: "Cancel"
                        onClicked: {
                            trustDialog.close()
                            wfCtrl.cancel_trust()
                        }
                    }
                }
            }
        }
    }
}
