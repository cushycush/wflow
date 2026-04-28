import QtQuick
import QtQuick.Controls
import Wflow

// Compact step list — the canvas-editor's left rail. Renders a vertical
// list of the workflow's steps with reorder + delete + add affordances,
// and emits selection / mutation signals for the parent to reconcile.
//
// Pulled out of SplitInspector so the same list works in the new
// canvas-only layout (rail + center canvas + slide-in inspector).
Item {
    id: root
    property var actions: []
    property int activeStepIndex: -1
    property int selectedIndex: -1
    property var stepStatuses: ({})

    signal selectRequested(int index)
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
        // `note` is now a per-step comment field on the inspector,
        // not an authorable step kind.
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

            // Section label
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
                height: parent.height - 40 - 16  // leave room for footer + label
                clip: true
                contentWidth: availableWidth

                Column {
                    width: parent.width
                    spacing: 1

                    Repeater {
                        model: root.actions
                        delegate: Rectangle {
                            id: stepRow
                            readonly property bool isSelected: model.index === root.selectedIndex
                            readonly property bool isActive: model.index === root.activeStepIndex
                            readonly property string status: {
                                const s = root.stepStatuses
                                if (!s) return ""
                                const v = s[model.index]
                                return v === undefined ? "" : v
                            }
                            readonly property color catColor: Theme.catFor(modelData.kind)

                            width: parent.width
                            height: 44
                            color: {
                                if (isSelected) return Qt.rgba(catColor.r, catColor.g, catColor.b, 0.15)
                                if (rowArea.containsMouse) return Theme.surface2
                                return "transparent"
                            }
                            Behavior on color { ColorAnimation { duration: Theme.durFast } }

                            MouseArea {
                                id: rowArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.selectRequested(model.index)
                            }

                            Row {
                                anchors.fill: parent
                                anchors.leftMargin: 14
                                anchors.rightMargin: 8
                                spacing: 10

                                Item {
                                    width: 18
                                    height: parent.height
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
                                CategoryIcon {
                                    kind: modelData.kind
                                    size: 22
                                    hovered: rowArea.containsMouse
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 18 - 10 - 22 - 10 - 70
                                    spacing: 1
                                    Text {
                                        text: modelData.summary
                                        color: Theme.text
                                        font.family: Theme.familyBody
                                        font.pixelSize: Theme.fontSm
                                        font.weight: stepRow.isSelected ? Font.DemiBold : Font.Medium
                                        elide: Text.ElideRight
                                        width: parent.width
                                    }
                                    Text {
                                        text: modelData.value
                                        color: Theme.text3
                                        font.family: Theme.familyMono
                                        font.pixelSize: 10
                                        elide: Text.ElideRight
                                        width: parent.width
                                    }
                                }
                            }

                            // Left edge selection bar — 2px accent
                            Rectangle {
                                visible: stepRow.isSelected
                                width: 2
                                height: parent.height - 12
                                radius: 1
                                x: 0
                                anchors.verticalCenter: parent.verticalCenter
                                color: stepRow.catColor
                            }

                            // Hover controls — ↑ ↓ × on the right edge
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
