import QtQuick
import QtQuick.Controls
import Wflow

// Triggers tab — bird's-eye view of every chord-bound workflow in the
// library. Each row shows the chord, the workflow's title, and edit
// / clear affordances. The "+ Bind a chord" button lists every
// workflow that doesn't have a chord yet so the user can pick one
// without leaving the page.
//
// Source of truth is LibraryController.workflows (already-loaded
// summaries, chord field per row). Mutations go through
// libCtrl.set_chord(id, chord); the daemon's file-watcher hot-reload
// picks the change up automatically — no daemon restart required.
Item {
    id: root
    signal openWorkflow(string id)

    LibraryController { id: libCtrl }

    readonly property var allWorkflows: {
        try {
            return JSON.parse(libCtrl.workflows) || []
        } catch (e) { return [] }
    }
    readonly property var triggered: root.allWorkflows.filter(w => w.chord && w.chord.length > 0)
    readonly property var untriggered: root.allWorkflows.filter(w => !w.chord || w.chord.length === 0)

    /// id of the workflow whose chord is currently being captured /
    /// edited. Cleared on dialog close.
    property string _editingId: ""

    ChordCaptureDialog {
        id: chordDialog
        onCaptured: (chord) => {
            if (root._editingId.length > 0) {
                libCtrl.set_chord(root._editingId, chord)
            }
            root._editingId = ""
        }
        onCleared: {
            if (root._editingId.length > 0) {
                libCtrl.set_chord(root._editingId, "")
            }
            root._editingId = ""
        }
    }

    // "Pick a workflow to bind" sheet. Shows untriggered workflows;
    // clicking one opens the chord capture dialog for that workflow.
    Dialog {
        id: workflowPickerDialog
        modal: true
        closePolicy: Popup.CloseOnEscape
        anchors.centerIn: parent
        width: 460
        height: Math.min(parent.height - 80, 520)

        header: Item { width: 0; height: 0 }
        footer: Item { width: 0; height: 0 }
        background: Rectangle {
            color: Theme.surface
            radius: Theme.radiusMd
            border.color: Theme.line
            border.width: 1
        }
        padding: 24

        contentItem: Column {
            spacing: 14

            Text {
                text: "Pick a workflow to bind"
                color: Theme.text
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontXl
                font.weight: Font.DemiBold
            }
            Text {
                text: root.untriggered.length === 0
                    ? "Every workflow already has a chord. Edit an existing binding above."
                    : "Pick the workflow you want to fire from a hotkey. The next screen captures the chord."
                color: Theme.text2
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                wrapMode: Text.WordWrap
                width: parent.width
                lineHeight: 1.4
            }

            ScrollView {
                width: parent.width
                height: 360
                clip: true
                visible: root.untriggered.length > 0
                Column {
                    width: parent.width
                    spacing: 4
                    Repeater {
                        model: root.untriggered
                        delegate: Rectangle {
                            width: parent.width
                            height: 48
                            radius: Theme.radiusSm
                            color: pickArea.containsMouse ? Theme.surface2 : "transparent"
                            border.color: pickArea.containsMouse ? Theme.lineSoft : "transparent"
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                            Column {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 1
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.title
                                    color: Theme.text
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontSm
                                    font.weight: Font.DemiBold
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.subtitle || (modelData.steps + " step" + (modelData.steps === 1 ? "" : "s"))
                                    color: Theme.text3
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontXs
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                            }
                            MouseArea {
                                id: pickArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root._editingId = modelData.id
                                    workflowPickerDialog.close()
                                    chordDialog.initialChord = ""
                                    chordDialog.open()
                                }
                            }
                        }
                    }
                }
            }

            Row {
                width: parent.width
                layoutDirection: Qt.RightToLeft
                SecondaryButton {
                    text: "Cancel"
                    onClicked: workflowPickerDialog.close()
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
            title: "Triggers"
            subtitle: root.triggered.length === 1
                ? "1 chord bound across the library"
                : root.triggered.length + " chords bound across the library"
        }

        ScrollView {
            width: parent.width
            height: parent.height - tb.height
            contentWidth: availableWidth
            clip: true

            Column {
                width: parent.width
                topPadding: 24
                bottomPadding: 40
                spacing: 24

                // Action bar at top — Bind a chord button.
                Item {
                    x: 24
                    width: parent.width - 48
                    height: bindBtn.implicitHeight + 8
                    Button {
                        id: bindBtn
                        text: "+  Bind a chord"
                        anchors.left: parent.left
                        topPadding: 10
                        bottomPadding: 10
                        leftPadding: 18
                        rightPadding: 18
                        background: Rectangle {
                            radius: Theme.radiusPill
                            color: bindBtn.hovered ? Theme.accentHi : Theme.accent
                            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                        }
                        contentItem: Text {
                            text: bindBtn.text
                            color: Theme.accentText
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            font.weight: Font.DemiBold
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        onClicked: workflowPickerDialog.open()
                    }
                }

                // Empty state — no triggers bound anywhere.
                Item {
                    visible: root.triggered.length === 0
                    width: parent.width
                    height: 200

                    Column {
                        anchors.centerIn: parent
                        spacing: 10
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "No triggers bound yet"
                            color: Theme.text2
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontMd
                            font.weight: Font.DemiBold
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: root.allWorkflows.length === 0
                                ? "Create a workflow first — Library → + New."
                                : "Bind a keyboard chord to fire any workflow with a tap."
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                        }
                    }
                }

                // Triggers list — one row per chord-bound workflow.
                Column {
                    visible: root.triggered.length > 0
                    x: 24
                    width: parent.width - 48
                    spacing: 8

                    Repeater {
                        model: root.triggered
                        delegate: Rectangle {
                            width: parent.width
                            height: 64
                            radius: Theme.radiusMd
                            color: rowHover.containsMouse ? Theme.surface2 : Theme.surface
                            border.color: rowHover.containsMouse ? Theme.lineStrong : Theme.line
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                            Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                            // Chord pill — left-anchored, mono, accent-tinted.
                            Rectangle {
                                anchors.left: parent.left
                                anchors.leftMargin: 16
                                anchors.verticalCenter: parent.verticalCenter
                                width: chordText.implicitWidth + 22
                                height: 32
                                radius: height / 2
                                color: Theme.accentDim
                                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
                                border.width: 1
                                Text {
                                    id: chordText
                                    anchors.centerIn: parent
                                    text: modelData.chord
                                    color: Theme.accent
                                    font.family: Theme.familyMono
                                    font.pixelSize: Theme.fontSm
                                    font.weight: Font.DemiBold
                                }
                            }

                            // Workflow title + step count, click → open in editor.
                            Column {
                                anchors.left: parent.left
                                anchors.leftMargin: 16 + chordText.implicitWidth + 22 + 16
                                anchors.right: actionsRow.left
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 1
                                Text {
                                    text: modelData.title
                                    color: Theme.text
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontSm
                                    font.weight: Font.DemiBold
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                                Text {
                                    text: modelData.subtitle && modelData.subtitle.length > 0
                                        ? modelData.subtitle
                                        : modelData.steps + " step" + (modelData.steps === 1 ? "" : "s")
                                    color: Theme.text3
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontXs
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                            }

                            // Edit / clear buttons. Sit on the right.
                            Row {
                                id: actionsRow
                                anchors.right: parent.right
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 6
                                SecondaryButton {
                                    text: "Edit"
                                    onClicked: {
                                        root._editingId = modelData.id
                                        chordDialog.initialChord = modelData.chord
                                        chordDialog.open()
                                    }
                                }
                                SecondaryButton {
                                    text: "Clear"
                                    onClicked: libCtrl.set_chord(modelData.id, "")
                                }
                            }

                            MouseArea {
                                id: rowHover
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton
                                propagateComposedEvents: true
                                // Click on the row body (outside the buttons)
                                // opens the workflow in the editor. Buttons
                                // accept first because they sit on top.
                                cursorShape: Qt.PointingHandCursor
                                onClicked: (mouse) => {
                                    // Fire only when clicked outside the actions row.
                                    const ax = actionsRow.x
                                    if (mouse.x < ax) {
                                        root.openWorkflow(modelData.id)
                                    }
                                }
                                z: -1  // sit behind action buttons so they take clicks
                            }
                        }
                    }
                }

                // Footer hint about the daemon picking up the change.
                Text {
                    visible: root.triggered.length > 0
                    x: 24
                    width: parent.width - 48
                    text: "The wflow daemon picks up these changes automatically — bind a chord and try it. No restart required on Hyprland or Sway."
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    wrapMode: Text.WordWrap
                    lineHeight: 1.4
                }
            }
        }
    }
}
