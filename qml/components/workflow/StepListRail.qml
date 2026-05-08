import QtQuick
import QtQuick.Controls
import Wflow

// Canvas-editor's left rail; vertical step list with reorder + delete
// + add affordances.
Item {
    id: root
    property var actions: []
    property int activeStepIndex: -1
    property int selectedIndex: -1
    property var selectedIndices: ({})
    property var stepStatuses: ({})

    signal selectRequested(int index)
    signal rangeSelectRequested(int index)
    signal toggleSelectRequested(int index)
    signal addStepRequested(string kind)
    signal deleteStepRequested(int stepIndex)
    signal moveStepRequested(int from, int to)

    property bool showTutorial: false
    signal tutorialDismissed()

    readonly property var _pickableKinds: [
        { kind: "key",       label: "Key chord" },
        { kind: "type",      label: "Type text" },
        { kind: "click",     label: "Click" },
        { kind: "move",      label: "Move cursor" },
        { kind: "scroll",    label: "Scroll" },
        { kind: "focus",     label: "Focus window" },
        { kind: "wait",      label: "Wait" },
        { kind: "shell",     label: "Shell command" },
        { kind: "notify",    label: "Notification" },
        { kind: "clipboard", label: "Clipboard" },
        // note is a per-step comment field now, not a step kind.
        { kind: "when",      label: "When (conditional)" },
        { kind: "unless",    label: "Unless (conditional)" },
        { kind: "repeat",    label: "Repeat block" },
        { kind: "use",       label: "Use named import" }
    ]

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusMd
        color: Theme.surface
        border.color: Theme.lineSoft
        border.width: 1

        Column {
            anchors.fill: parent
            anchors.topMargin: 14
            anchors.bottomMargin: 8
            spacing: 0

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 16
                text: "STEPS"
                color: Theme.text3
                font.family: Theme.familyBody
                font.pixelSize: 10
                font.weight: Font.Bold
                font.letterSpacing: 1.2
                bottomPadding: 8
            }

            ScrollView {
                width: parent.width
                height: parent.height - 40 - 16  // footer + label
                clip: true
                contentWidth: availableWidth

                Column {
                    width: parent.width
                    spacing: 1

                    Repeater {
                        model: root.actions
                        delegate: Rectangle {
                            id: stepRow
                            readonly property bool isSelected:
                                root.selectedIndices && root.selectedIndices[model.index] === true
                            readonly property bool isActive: model.index === root.activeStepIndex
                            readonly property string status: {
                                const s = root.stepStatuses
                                if (!s) return ""
                                const v = s[model.index]
                                return v === undefined ? "" : v
                            }
                            readonly property color catColor: Theme.catFor(modelData.kind)

                            width: parent.width
                            height: 34
                            // Accent wash on multi-row selection so the range
                            // reads as one band instead of varied catColors.
                            color: {
                                if (isSelected) return Theme.wash(Theme.accent, 0.18)
                                if (rowArea.containsMouse) return Theme.surface2
                                return "transparent"
                            }
                            Behavior on color { ColorAnimation { duration: Theme.durFast } }

                            Rectangle {
                                visible: stepRow.isSelected
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                width: 2
                                color: Theme.accent
                            }

                            MouseArea {
                                id: rowArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: (mouse) => {
                                    if (mouse.modifiers & Qt.ShiftModifier) {
                                        root.rangeSelectRequested(model.index)
                                    } else if (mouse.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) {
                                        root.toggleSelectRequested(model.index)
                                    } else {
                                        root.selectRequested(model.index)
                                    }
                                }
                            }

                            // Row geometry: status badge on the left,
                            // chip filling the middle, action affordances
                            // pinned to the right (rendered separately
                            // below, so the chip can stretch under them).
                            Item {
                                id: statusBadge
                                width: 18
                                height: parent.height
                                anchors.left: parent.left
                                anchors.leftMargin: 14
                                anchors.verticalCenter: parent.verticalCenter

                                Text {
                                    anchors.centerIn: parent
                                    visible: stepRow.status === ""
                                    text: String(model.index + 1).padStart(2, "0")
                                    color: stepRow.isActive ? stepRow.catColor : Theme.text3
                                    font.family: Theme.familyMono
                                    font.pixelSize: 10
                                }
                                Text {
                                    anchors.centerIn: parent
                                    visible: stepRow.status !== ""
                                    text: stepRow.status === "ok"      ? "✓"
                                        : stepRow.status === "error"   ? "✗"
                                        : stepRow.status === "skipped" ? "·"
                                        : ""
                                    color: stepRow.status === "ok"      ? Theme.ok
                                         : stepRow.status === "error"   ? Theme.err
                                         : Theme.text3
                                    font.family: Theme.familyBody
                                    font.pixelSize: 13
                                    font.weight: Font.Bold
                                }
                            }

                            // Library-style chip; same pill + dot +
                            // abbreviation rules as the canvas hero and
                            // the library trail. Action affordances are
                            // rendered as a sibling Row anchored right.
                            StepChip {
                                anchors.left: statusBadge.right
                                anchors.leftMargin: 10
                                anchors.right: parent.right
                                anchors.rightMargin: 78
                                anchors.verticalCenter: parent.verticalCenter
                                kind: modelData.kind
                                value: modelData.editable
                                    ? (modelData.rawPrimary || modelData.value || "")
                                    : (modelData.value || "")
                                height: 24
                                fontSize: 10
                            }

                            Rectangle {
                                visible: stepRow.isSelected
                                width: 2
                                height: parent.height - 12
                                radius: 1
                                x: 0
                                anchors.verticalCenter: parent.verticalCenter
                                color: stepRow.catColor
                            }

                            Row {
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 1
                                opacity: (rowArea.containsMouse
                                          || upArea.containsMouse
                                          || downArea.containsMouse
                                          || delArea.containsMouse
                                          || stepRow.isSelected) ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: Theme.durFast } }

                                Rectangle {
                                    width: 20; height: 20; radius: 3
                                    color: upArea.containsMouse ? Theme.surface3 : "transparent"
                                    Text {
                                        anchors.centerIn: parent
                                        text: "↑"
                                        color: model.index === 0 ? Theme.text3 : Theme.text2
                                        font.family: Theme.familyBody
                                        font.pixelSize: 12
                                    }
                                    MouseArea {
                                        id: upArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        enabled: model.index > 0
                                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                        onClicked: root.moveStepRequested(model.index, model.index - 1)
                                    }
                                }
                                Rectangle {
                                    width: 20; height: 20; radius: 3
                                    color: downArea.containsMouse ? Theme.surface3 : "transparent"
                                    Text {
                                        anchors.centerIn: parent
                                        text: "↓"
                                        color: model.index === root.actions.length - 1
                                            ? Theme.text3 : Theme.text2
                                        font.family: Theme.familyBody
                                        font.pixelSize: 12
                                    }
                                    MouseArea {
                                        id: downArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        enabled: model.index < root.actions.length - 1
                                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                        onClicked: root.moveStepRequested(model.index, model.index + 1)
                                    }
                                }
                                Rectangle {
                                    width: 20; height: 20; radius: 3
                                    color: delArea.containsMouse
                                        ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.18)
                                        : "transparent"
                                    Text {
                                        anchors.centerIn: parent
                                        text: "×"
                                        color: delArea.containsMouse ? Theme.err : Theme.text2
                                        font.family: Theme.familyBody
                                        font.pixelSize: 14
                                    }
                                    MouseArea {
                                        id: delArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.deleteStepRequested(model.index)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Add-step footer
            Rectangle {
                width: parent.width
                height: 40
                color: addArea.containsMouse ? Theme.surface2 : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.durFast } }

                TutorialOverlay {
                    anchors.bottom: parent.top
                    anchors.bottomMargin: 4
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Start by adding a step. Try Type text or Press key."
                    visible: root.showTutorial
                    onDismissed: root.tutorialDismissed()
                    z: 10
                }

                Row {
                    anchors.centerIn: parent
                    spacing: 8
                    Text {
                        text: "+"
                        color: Theme.accent
                        font.family: Theme.familyBody
                        font.pixelSize: 16
                        font.weight: Font.Bold
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: "Add step"
                        color: Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.Medium
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    id: addArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: kindMenu.popup()
                }

                WfMenu {
                    id: kindMenu
                    Repeater {
                        model: root._pickableKinds
                        delegate: WfMenuItem {
                            text: modelData.label
                            onTriggered: root.addStepRequested(modelData.kind)
                        }
                    }
                }
            }
        }
    }
}
