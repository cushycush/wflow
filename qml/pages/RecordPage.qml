import QtQuick
import QtQuick.Controls
import Wflow

// State machine: idle → armed → recording → stopped → finalize().
Item {
    id: root

    signal openWorkflow(string id)

    property alias recordSurface: ambient

    RecorderController { id: recCtrl }

    property var events: []

    Connections {
        target: recCtrl
        function onEvent_captured(kind, t_ms, summary) {
            const a = root.events.slice()
            a.push({ t_ms: t_ms, category: kind, body: summary })
            root.events = a
        }
    }

    // Same cxx-qt snake_case Connections gotcha as WorkflowPage; the
    // property binding path fires reliably.
    property string _eventsJsonMirror: recCtrl.events_json
    on_EventsJsonMirrorChanged: {
        if (recCtrl.state !== "stopped") return
        try {
            const raw = JSON.parse(_eventsJsonMirror || "[]")
            root.events = raw.map(ev => _shapeRecEvent(ev))
        } catch (e) { /* keep local copy */ }
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
        saveDialog.open()
    }

    function _commitFinalize(title) {
        const t = (title || "").trim() || "Recorded workflow"
        const id = recCtrl.finalize(t)
        if (id && id.length > 0) {
            root.events = []
            root.openWorkflow(id)
        }
    }

    // Default Dialog chrome inherits the system Qt style and renders
    // the TextField text unreadably against our dark surface; build
    // bespoke chrome.
    Dialog {
        id: saveDialog
        modal: true
        closePolicy: Popup.CloseOnEscape
        width: 420
        anchors.centerIn: parent

        header: Item { width: 0; height: 0 }
        footer: Item { width: 0; height: 0 }

        background: Rectangle {
            color: Theme.surface
            radius: Theme.radiusMd
            border.color: Theme.line
            border.width: 1
        }

        onAboutToShow: {
            nameField.text = "Recorded workflow"
            Qt.callLater(function() {
                nameField.forceActiveFocus()
                nameField.selectAll()
            })
        }

        onAccepted: root._commitFinalize(nameField.text)

        contentItem: Item {
            anchors.fill: parent

            Column {
                anchors.fill: parent
                anchors.margins: 24
                spacing: 16

                Column {
                    width: parent.width
                    spacing: 4
                    Text {
                        text: "Save recorded workflow"
                        color: Theme.text
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontXl
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: "Pick a name for the new workflow."
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 48
                    radius: Theme.radiusMd
                    color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 1)
                    border.color: nameField.activeFocus ? Theme.accent : Theme.line
                    border.width: nameField.activeFocus ? 2 : 1
                    Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

                    TextField {
                        id: nameField
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        verticalAlignment: TextInput.AlignVCenter
                        color: Theme.text
                        placeholderText: "Recorded workflow"
                        placeholderTextColor: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontMd
                        selectByMouse: true
                        background: Item {}
                        onAccepted: saveDialog.accept()
                    }
                }

                Row {
                    width: parent.width
                    spacing: 8
                    layoutDirection: Qt.RightToLeft

                    PrimaryButton {
                        text: "Save"
                        enabled: nameField.text.trim().length > 0
                        onClicked: saveDialog.accept()
                    }
                    SecondaryButton {
                        text: "Cancel"
                        onClicked: saveDialog.reject()
                    }
                }
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
            subtitle: recCtrl.state === "armed" ? "ready. perform the task"
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

        // Surfaces last_error; usually a missing RemoteDesktop portal
        // or a cancelled consent dialog.
        Rectangle {
            id: recErrBanner
            property bool _dismissed: false
            property string _lastErrorMirror: recCtrl.last_error
            on_LastErrorMirrorChanged: _dismissed = false

            visible: !_dismissed && recCtrl.last_error !== ""
            width: parent.width
            height: visible ? errCol.implicitHeight + 20 : 0
            color: Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.10)

            Rectangle {
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                height: 1
                color: Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.45)
            }

            Row {
                anchors.fill: parent
                anchors.leftMargin: 24
                anchors.rightMargin: 16
                spacing: 12

                Rectangle {
                    width: 22
                    height: 22
                    radius: Theme.radiusSm
                    anchors.verticalCenter: parent.verticalCenter
                    color: Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.25)
                    Text {
                        anchors.centerIn: parent
                        text: "!"
                        color: Theme.err
                        font.family: Theme.familyBody
                        font.pixelSize: 14
                        font.weight: Font.Bold
                    }
                }

                Column {
                    id: errCol
                    width: parent.width - 22 - 12 - 28 - 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Text {
                        text: "Record can't start"
                        color: Theme.err
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: recCtrl.last_error
                        color: Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontXs
                        width: parent.width
                        wrapMode: Text.WordWrap
                    }
                }

                Rectangle {
                    width: 24
                    height: 24
                    radius: Theme.radiusSm
                    anchors.verticalCenter: parent.verticalCenter
                    color: dismissRecErrArea.containsMouse
                        ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.20)
                        : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.durFast } }
                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        color: dismissRecErrArea.containsMouse ? Theme.err : Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: 14
                        font.weight: Font.Bold
                    }
                    MouseArea {
                        id: dismissRecErrArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: recErrBanner._dismissed = true
                    }
                }
            }
        }

        AmbientRec {
            id: ambient
            width: parent.width
            height: parent.height - tb.height
                - (recErrBanner.visible ? recErrBanner.height : 0)
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
