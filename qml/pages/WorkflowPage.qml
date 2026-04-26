import QtQuick
import QtQuick.Controls
import Wflow

// Workflow editor. WorkflowController loads on mount, edits debounce-save
// at ~600ms, step progress streams via active_step + step_done signals.
Item {
    id: root
    property string workflowId: ""
    signal backRequested()

    WorkflowController { id: wfCtrl }
    StateController { id: stateCtrl }

    // Held locally so the editor has a live target to mutate before
    // load() returns and during in-flight edits.
    property var workflow: ({
        id: "",
        title: "Untitled workflow",
        subtitle: "",
        steps: []
    })

    // idle → dirty → saving → saved → idle, or error on failure.
    property string saveState: "idle"

    property var stepStatuses: ({})

    property string trustSummary: ""

    // Session-only; long-term flag is state.toml tutorials.blank_workflow_seen.
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
        // Inspector binds option editors directly off rawAction.
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

    // Kind-aware so "500" on a delay becomes {ms: 500}, not a string.
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

    // path is "enabled" | "on_error" | "note" | "action.<field>".
    // Empty value on an Option<T> action field deletes the key so
    // serde defaults round-trip cleanly.
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
        // Rust side only requires `id` to be unique, not a real UUID.
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
        steps.push({
            id: _uuid(),
            enabled: true,
            on_error: "stop",
            action: _defaultActionForKind(kind)
        })
        wf.steps = steps
        root.workflow = wf
        splitInspector.selectedIndex = steps.length - 1
        _scheduleSave()
    }

    function _deleteStep(stepIndex) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = wf.steps || []
        if (stepIndex < 0 || stepIndex >= steps.length) return
        steps.splice(stepIndex, 1)
        wf.steps = steps
        root.workflow = wf
        // Keep a valid selection: clamp to the last remaining step.
        if (splitInspector.selectedIndex >= steps.length) {
            splitInspector.selectedIndex = Math.max(0, steps.length - 1)
        }
        _scheduleSave()
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
        // Follow the moved step with the selection so the inspector keeps
        // looking at the same thing the user just dragged.
        if (splitInspector.selectedIndex === from) {
            splitInspector.selectedIndex = to
        } else if (from < splitInspector.selectedIndex && to >= splitInspector.selectedIndex) {
            splitInspector.selectedIndex -= 1
        } else if (from > splitInspector.selectedIndex && to <= splitInspector.selectedIndex) {
            splitInspector.selectedIndex += 1
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

    Shortcut {
        sequence: "Ctrl+Return"
        enabled: root.visible && (root.actions || []).length > 0 && !root.running
        onActivated: wfCtrl.run()
    }

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
            width: parent.width
            height: parent.height - tb.height

            EmptyState {
                anchors.fill: parent
                visible: !root.workflowId
                title: "No workflow loaded"
                description: "Pick one from the library, or create a new one."
                actionLabel: ""
            }

            SplitInspector {
                id: splitInspector
                anchors.fill: parent
                anchors.margins: 24
                visible: root.workflowId.length > 0
                actions: root.actions
                activeStepIndex: root.activeStepIndex
                running: root.running
                stepStatuses: root.stepStatuses

                // First-time tutorial tooltip on the + Add step
                // footer. Shown only when (a) the workflow has no
                // steps, AND (b) the user hasn't dismissed it on
                // this machine before. Cached at activation time so
                // it doesn't flicker off the moment the user adds
                // their first step.
                showTutorial: _shouldShowBlankTutorial
                onTutorialDismissed: {
                    stateCtrl.mark_tutorial_seen("blank_workflow")
                    root._tutorialDismissedThisSession = true
                }

                onValueEdited: (stepIndex, newPrimary) => root._commitStepEdit(stepIndex, newPrimary)
                onOptionEdited: (stepIndex, path, value) => root._commitOption(stepIndex, path, value)
                onAddStepRequested: (kind) => root._addStep(kind)
                onDeleteStepRequested: (stepIndex) => root._deleteStep(stepIndex)
                onMoveStepRequested: (from, to) => root._moveStep(from, to)
            }
        }
    }

    // Engine waits for confirm_trust() / cancel_trust() before running.
    // Mirrors the CLI prompt body (src/security.rs).
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

                Column {
                    width: parent.width
                    spacing: 6

                    Row {
                        spacing: 10
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

                ScrollView {
                    width: parent.width
                    height: parent.height - parent.spacing * 2 - 80 - 56
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
