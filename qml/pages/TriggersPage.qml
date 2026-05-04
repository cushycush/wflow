import QtQuick
import QtQuick.Controls
import Wflow

// libCtrl.set_chord mutations propagate through the daemon's
// file-watcher hot-reload; no daemon restart needed.
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

    property string _editingId: ""
    property string _pickerFilter: ""

    ChordCaptureDialog {
        id: chordDialog
        onCaptured: (chord, whenKind, whenValue) => {
            if (root._editingId.length > 0) {
                libCtrl.set_chord(root._editingId, chord, whenKind, whenValue)
            }
            root._editingId = ""
        }
        onCleared: {
            if (root._editingId.length > 0) {
                libCtrl.set_chord(root._editingId, "", "", "")
            }
            root._editingId = ""
        }
    }

    readonly property var _filteredUntriggered: {
        const q = root._pickerFilter.toLowerCase().trim()
        if (q.length === 0) return root.untriggered
        return root.untriggered.filter(w => {
            const t = (w.title || "").toLowerCase()
            const s = (w.subtitle || "").toLowerCase()
            return t.indexOf(q) >= 0 || s.indexOf(q) >= 0
        })
    }

    Dialog {
        id: workflowPickerDialog
        modal: true
        closePolicy: Popup.CloseOnEscape
        anchors.centerIn: parent
        width: 460
        height: Math.min(parent.height - 80, 520)
        onClosed: root._pickerFilter = ""

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

            TextField {
                id: pickerSearch
                visible: root.untriggered.length > 6
                width: parent.width
                placeholderText: "Filter workflows…"
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                color: Theme.text
                placeholderTextColor: Theme.text3
                background: Rectangle {
                    radius: Theme.radiusSm
                    color: pickerSearch.activeFocus
                        ? Theme.surface2
                        : Qt.rgba(Theme.surface2.r, Theme.surface2.g, Theme.surface2.b, 0.5)
                    border.color: pickerSearch.activeFocus ? Theme.accent : Theme.lineSoft
                    border.width: 1
                    Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                }
                onTextChanged: root._pickerFilter = text
            }

            ScrollView {
                width: parent.width
                height: pickerSearch.visible ? 320 : 360
                clip: true
                visible: root.untriggered.length > 0
                contentWidth: availableWidth

                Column {
                    width: parent.width
                    spacing: 4
                    Text {
                        visible: root._filteredUntriggered.length === 0
                            && root.untriggered.length > 0
                        text: "No workflows match \"" + root._pickerFilter + "\""
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.italic: true
                        topPadding: 8
                        leftPadding: 4
                    }
                    Repeater {
                        model: root._filteredUntriggered
                        delegate: Rectangle {
                            width: parent.width
                            height: 56
                            radius: Theme.radiusSm
                            color: pickArea.containsMouse ? Theme.surface2 : "transparent"
                            border.color: pickArea.containsMouse ? Theme.lineSoft : "transparent"
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                            // Wrapper Item, then Column inside; no
                            // anchors on the Column's children (anchors
                            // fight Column positioning and stacked
                            // every title at y=0).
                            Item {
                                anchors.fill: parent
                                anchors.leftMargin: 14
                                anchors.rightMargin: 14
                                Column {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 2
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
                                    chordDialog.initialWhenKind = ""
                                    chordDialog.initialWhenValue = ""
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
                                ? "Create a workflow first, Library → + New."
                                : "Bind a keyboard chord to fire any workflow with a tap."
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                        }
                    }
                }

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
                                    text: {
                                        const k = modelData.chord_when_kind || ""
                                        const v = modelData.chord_when_value || ""
                                        if (k && v) {
                                            const verb = k === "window-class"
                                                ? "when window class is"
                                                : "when window title contains"
                                            return verb + " " + v
                                        }
                                        return modelData.subtitle && modelData.subtitle.length > 0
                                            ? modelData.subtitle
                                            : modelData.steps + " step" + (modelData.steps === 1 ? "" : "s")
                                    }
                                    color: Theme.text3
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontXs
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                            }

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
                                        chordDialog.initialWhenKind = modelData.chord_when_kind || ""
                                        chordDialog.initialWhenValue = modelData.chord_when_value || ""
                                        chordDialog.open()
                                    }
                                }
                                SecondaryButton {
                                    text: "Clear"
                                    onClicked: libCtrl.set_chord(modelData.id, "", "", "")
                                }
                            }

                            MouseArea {
                                id: rowHover
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton
                                propagateComposedEvents: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: (mouse) => {
                                    const ax = actionsRow.x
                                    if (mouse.x < ax) {
                                        root.openWorkflow(modelData.id)
                                    }
                                }
                                z: -1  // behind action buttons
                            }
                        }
                    }
                }

                Text {
                    visible: root.triggered.length > 0
                    x: 24
                    width: parent.width - 48
                    text: "The wflow daemon picks up these changes automatically, bind a chord and try it. No restart required on Hyprland or Sway."
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
