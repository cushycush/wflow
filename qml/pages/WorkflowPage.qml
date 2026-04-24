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
        switch (kind) {
        case "wdo_type":            return { kind: "type",     summary: "Type text",         value: act.text,                              rawPrimary: act.text,        editable: true }
        case "wdo_key":             return { kind: "key",      summary: "Press key chord",   value: act.chord,                             rawPrimary: act.chord,       editable: true }
        case "wdo_key_down":        return { kind: "key",      summary: "Hold key",          value: act.chord,                             rawPrimary: act.chord,       editable: true }
        case "wdo_key_up":          return { kind: "key",      summary: "Release key",       value: act.chord,                             rawPrimary: act.chord,       editable: true }
        case "wdo_click":           return { kind: "click",    summary: "Mouse click",       value: "button " + act.button,                rawPrimary: String(act.button), editable: true, intOnly: true }
        case "wdo_mouse_down":      return { kind: "click",    summary: "Hold button",       value: "button " + act.button,                rawPrimary: String(act.button), editable: true, intOnly: true }
        case "wdo_mouse_up":        return { kind: "click",    summary: "Release button",    value: "button " + act.button,                rawPrimary: String(act.button), editable: true, intOnly: true }
        case "wdo_mouse_move":      return { kind: "move",     summary: "Move cursor",       value: "(" + act.x + ", " + act.y + ")",      rawPrimary: act.x + ", " + act.y, editable: false }
        case "wdo_scroll":          return { kind: "scroll",   summary: "Scroll",            value: "dx " + act.dx + " dy " + act.dy,      rawPrimary: act.dx + ", " + act.dy, editable: false }
        case "wdo_activate_window": return { kind: "focus",    summary: "Focus window",      value: act.name,                              rawPrimary: act.name,        editable: true }
        case "wdo_await_window":    return { kind: "wait",     summary: "Wait for window",   value: act.name,                              rawPrimary: act.name,        editable: true }
        case "delay":               return { kind: "wait",     summary: "Wait",              value: act.ms + " ms",                        rawPrimary: String(act.ms),  editable: true, intOnly: true, unit: "ms" }
        case "shell":               return { kind: "shell",    summary: "Run shell command", value: act.command,                           rawPrimary: act.command,     editable: true }
        case "notify":              return { kind: "notify",   summary: "Notify",            value: act.title,                             rawPrimary: act.title,       editable: true }
        case "clipboard":           return { kind: "clipboard",summary: "Copy to clipboard", value: act.text,                              rawPrimary: act.text,        editable: true }
        case "note":                return { kind: "note",     summary: "Note",              value: act.text,                              rawPrimary: act.text,        editable: true }
        // Flow-control actions — read-only in the GUI for now. They round-trip through the KDL file but edit via $EDITOR.
        case "repeat":              return { kind: "wait",     summary: "Repeat " + act.count + "×", value: (act.steps || []).length + " inner step(s)", rawPrimary: "", editable: false }
        case "conditional":         return { kind: "wait",     summary: (act.negate ? "Unless" : "When"), value: _condSummary(act.cond),                 rawPrimary: "", editable: false }
        case "include":             return { kind: "shell",    summary: "Include",           value: act.path,                              rawPrimary: act.path,        editable: true }
        case "use":                 return { kind: "shell",    summary: "Use import",        value: act.name,                              rawPrimary: act.name,        editable: true }
        }
        return { kind: "note", summary: kind, value: "", rawPrimary: "", editable: false }
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

            Button {
                text: "↗ Share"
                topPadding: 8; bottomPadding: 8; leftPadding: 14; rightPadding: 14
                background: Rectangle {
                    radius: Theme.radiusSm
                    color: parent.hovered ? Theme.surface3 : Theme.surface2
                    border.color: Theme.line
                    border.width: 1
                }
                contentItem: Text {
                    text: parent.text; color: Theme.text
                    font.family: Theme.familyBody; font.pixelSize: Theme.fontSm; font.weight: Font.Medium
                }
            }
            Button {
                id: runBtn
                text: root.running ? "⏸ Running…" : "▶ Run"
                topPadding: 8; bottomPadding: 8; leftPadding: 18; rightPadding: 18
                enabled: (root.actions || []).length > 0 && !root.running
                background: Rectangle {
                    radius: Theme.radiusSm
                    color: parent.enabled
                        ? (parent.hovered ? Theme.accentHi : Theme.accent)
                        : Theme.surface3
                }
                contentItem: Text {
                    text: parent.text
                    color: parent.enabled ? Theme.accentText : Theme.text3
                    font.family: Theme.familyBody; font.pixelSize: Theme.fontSm; font.weight: Font.DemiBold
                }
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
            width: parent.width
            height: parent.height - tb.height

            EmptyState {
                anchors.fill: parent
                visible: (root.actions || []).length === 0
                title: "No steps yet"
                description: "Add actions below or hit Record to capture keystrokes, clicks, and shell commands into a ready-to-run workflow."
                actionLabel: ""
            }

            SplitInspector {
                id: splitInspector
                anchors.fill: parent
                anchors.margins: 24
                visible: (root.actions || []).length > 0
                actions: root.actions
                activeStepIndex: root.activeStepIndex
                running: root.running
                stepStatuses: root.stepStatuses
                onValueEdited: (stepIndex, newPrimary) => root._commitStepEdit(stepIndex, newPrimary)
            }
        }
    }
}
