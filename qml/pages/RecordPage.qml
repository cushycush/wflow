import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Wflow

// Record Mode — ambient layout.
//
// Wires RecorderController (cxx-qt). arm() flips the state machine from
// "idle" to "armed" to "recording" as the recorder backend pushes frames
// back. Each captured event appends to `events`. On stop, the recent list
// is shown; a final button lets the user finalize the capture into a
// saved workflow via finalize(title).
Item {
    id: root

    signal openWorkflow(string id)

    RecorderController { id: recCtrl }

    property var events: []

    // Bridge posts RecFrame{Event} as a signal. We append a shaped view
    // that AmbientRec can render.
    Connections {
        target: recCtrl
        function onEvent_captured(kind, t_ms, summary) {
            const a = root.events.slice()
            a.push({ t_ms: t_ms, category: kind, body: summary })
            root.events = a
        }
        // When the session has fully settled and events_json is fresh,
        // re-hydrate from it so finalize sees the same view we render.
        function onEvents_jsonChanged() {
            if (recCtrl.state !== "stopped") return
            try {
                const raw = JSON.parse(recCtrl.events_json || "[]")
                root.events = raw.map(ev => _shapeRecEvent(ev))
            } catch (e) { /* keep local copy */ }
        }
    }

    function _shapeRecEvent(ev) {
        const k = ev.kind
        switch (k) {
        case "key":          return { t_ms: ev.t_ms, category: "key",    body: ev.chord }
        case "text":         return { t_ms: ev.t_ms, category: "type",   body: ev.text }
        case "click":        return { t_ms: ev.t_ms, category: "click",  body: "button " + ev.button }
        case "move":         return { t_ms: ev.t_ms, category: "move",   body: "(" + ev.x + ", " + ev.y + ")" }
        case "scroll":       return { t_ms: ev.t_ms, category: "scroll", body: "dx " + ev.dx + " dy " + ev.dy }
        case "window_focus": return { t_ms: ev.t_ms, category: "focus",  body: ev.name }
        case "gap":          return { t_ms: ev.t_ms, category: "wait",   body: ev.ms + " ms" }
        }
        return { t_ms: ev.t_ms || 0, category: "note", body: k }
    }

    function _onArm() {
        root.events = []
        recCtrl.arm()
    }
    function _onStop() {
        recCtrl.stop()
    }
    function _finalize() {
        // Open the name dialog. The actual finalize call happens in
        // saveDialog.onAccepted so the user gets to title their
        // workflow before the file lands on disk.
        nameField.text = "Recorded workflow"
        saveDialog.open()
        Qt.callLater(function() {
            nameField.forceActiveFocus()
            nameField.selectAll()
        })
    }

    function _commitFinalize(title) {
        const t = (title || "").trim() || "Recorded workflow"
        const id = recCtrl.finalize(t)
        if (id && id.length > 0) {
            root.events = []
            root.openWorkflow(id)
        }
    }

    Dialog {
        id: saveDialog
        modal: true
        anchors.centerIn: parent
        width: 420
        title: "Save recorded workflow"
        standardButtons: Dialog.Save | Dialog.Cancel
        onAccepted: root._commitFinalize(nameField.text)

        ColumnLayout {
            width: parent.width
            spacing: 8
            Text {
                text: "Workflow name"
                color: Theme.text2
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
            }
            TextField {
                id: nameField
                Layout.fillWidth: true
                placeholderText: "Recorded workflow"
                color: Theme.text
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontMd
                selectByMouse: true
                onAccepted: saveDialog.accept()
            }
            Text {
                text: "Saved as a new workflow in your library."
                color: Theme.text3
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontXs
            }
        }
    }

    Column {
        anchors.fill: parent
        spacing: 0

        TopBar {
            id: tb
            width: parent.width
            title: "Record"
            subtitle: recCtrl.state === "armed" ? "ready — perform the task"
                    : recCtrl.state === "recording" ? "recording your actions"
                    : recCtrl.state === "stopped" ? "review and save the capture"
                    : "perform once, wflow transcribes it into a workflow"

            PrimaryButton {
                visible: recCtrl.state === "stopped" && root.events.length > 0
                text: "Save as workflow"
                leftPadding: 18
                rightPadding: 18
                onClicked: root._finalize()
            }
        }

        // Portal failure banner. Surfaces the error string the bridge
        // set on `last_error` (most often: the user's compositor portal
        // doesn't expose RemoteDesktop, or the consent dialog was
        // cancelled). Stays visible until the next arm() resets it.
        Rectangle {
            visible: recCtrl.last_error !== ""
            width: parent.width
            color: Theme.surface2
            border.color: Theme.err
            border.width: 1
            radius: 8
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            implicitHeight: errCol.implicitHeight + 24

            Column {
                id: errCol
                anchors.fill: parent
                anchors.margins: 12
                spacing: 4

                Text {
                    text: "Record can't start"
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 14
                    font.weight: Font.Medium
                }
                Text {
                    text: recCtrl.last_error
                    color: Theme.text2
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                    width: parent.width
                    wrapMode: Text.WordWrap
                }
            }
        }

        AmbientRec {
            width: parent.width
            height: parent.height - tb.height - (recCtrl.last_error !== "" ? 80 : 0)
            // After stop the AmbientRec drops back to "idle" so the
            // central button switches from a square (stop) back to a
            // circle (arm again) and the "RECORDING" pulse stops. The
            // stopped-state controls (Save as workflow, event list)
            // live above this in the TopBar so the user still has a
            // path to keep the capture.
            phase: recCtrl.state === "armed" || recCtrl.state === "recording"
                ? recCtrl.state
                : "idle"
            totalMs: recCtrl.elapsed_ms
            events: root.events
            onArmRequested: root._onArm()
            onStopRequested: root._onStop()
        }
    }
}
