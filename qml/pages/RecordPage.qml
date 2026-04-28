import QtQuick
import QtQuick.Controls
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
    }

    // Mirror recCtrl.events_json into a local property so we can hook
    // a property-change handler that actually fires. Connections +
    // `function onEvents_jsonChanged()` doesn't catch cxx-qt's auto-
    // generated NOTIFY signal for snake_case Q_PROPERTY names — same
    // gotcha that broke WorkflowPage's onWorkflow_jsonChanged. The
    // property-binding path here is reliable.
    property string _eventsJsonMirror: recCtrl.events_json
    on_EventsJsonMirrorChanged: {
        // When the session has fully settled and events_json is
        // fresh, re-hydrate from it so finalize sees the same view
        // we render.
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

    // Save-as-workflow prompt. Built bespoke (no standardButtons,
    // custom background, framed TextField) so the visuals match
    // the rest of the app — Qt's default Dialog chrome picks up
    // the system Qt style which doesn't agree with our dark theme
    // and renders the TextField text in a hard-to-read color.
    Dialog {
        id: saveDialog
        modal: true
        closePolicy: Popup.CloseOnEscape
        width: 420
        anchors.centerIn: parent

        // Suppress the system header / footer bars; the contentItem
        // renders our own header text and the footer Row of buttons.
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

                // Framed input. The chrome lives in the wrapping
                // Rectangle; the TextField's own background is
                // transparent so its text renders against our dark
                // surface (mirrors the SplitInspector valueField
                // pattern).
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
        // cancelled). Same banner shape as the editor's error
        // banner — tinted bg, !-badge, dismissable ×.
        Rectangle {
            id: recErrBanner
            property bool _dismissed: false
            // Mirror last_error so the change handler reliably fires
            // (cxx-qt snake_case Q_PROPERTY → Connections' function-
            // syntax handler doesn't catch it; property-binding does).
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
