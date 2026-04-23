import QtQuick
import QtQuick.Controls
import Wflow

// Workflow editor.
//
// Data flows through WorkflowController: we load(id) on mount, decode the
// returned JSON for the title / steps, and call run() to fire the real
// engine on the Rust side. Step progress streams back via the
// active_step property and step_done / run_finished signals.
Item {
    id: root
    property string workflowId: ""
    signal backRequested()

    WorkflowController { id: wfCtrl }

    // Decoded workflow object. Kept as a local property so the editor can
    // present placeholder text before load() returns.
    property var workflow: ({
        id: "",
        title: "Untitled workflow",
        subtitle: "",
        steps: []
    })

    readonly property string title:    workflow.title || "Untitled workflow"
    readonly property string subtitle: workflow.subtitle || ""
    readonly property int activeStepIndex: wfCtrl.active_step
    readonly property bool running: wfCtrl.running
    readonly property var actions: {
        // Shape the Rust-side Step[] into the { kind, summary, value }
        // the action-row delegates expect.
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
        case "wdo_type":            return { kind: "type",     summary: "Type text",         value: act.text }
        case "wdo_key":             return { kind: "key",      summary: "Press key chord",   value: act.chord }
        case "wdo_click":           return { kind: "click",    summary: "Mouse click",       value: "button " + act.button }
        case "wdo_mouse_move":      return { kind: "move",     summary: "Move cursor",       value: "(" + act.x + ", " + act.y + ")" }
        case "wdo_scroll":          return { kind: "scroll",   summary: "Scroll",            value: "dx " + act.dx + " dy " + act.dy }
        case "wdo_activate_window": return { kind: "focus",    summary: "Focus window",      value: act.name }
        case "delay":               return { kind: "wait",     summary: "Wait",              value: act.ms + " ms" }
        case "shell":               return { kind: "shell",    summary: "Run shell command", value: act.command }
        case "notify":              return { kind: "notify",   summary: "Notify",            value: act.title }
        case "clipboard":           return { kind: "clipboard",summary: "Copy to clipboard", value: act.text }
        case "note":                return { kind: "note",     summary: "Note",              value: act.text }
        }
        return { kind: "note", summary: kind, value: "" }
    }

    onWorkflowIdChanged: _reload()
    Component.onCompleted: _reload()

    function _reload() {
        if (!root.workflowId) {
            root.workflow = { id: "", title: "Untitled workflow", subtitle: "", steps: [] }
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
    }

    Column {
        anchors.fill: parent
        spacing: 0

        TopBar {
            id: tb
            width: parent.width
            title: root.title
            subtitle: root.subtitle

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
                anchors.fill: parent
                anchors.margins: 24
                visible: (root.actions || []).length > 0
                actions: root.actions
                activeStepIndex: root.activeStepIndex
                running: root.running
            }
        }
    }
}
