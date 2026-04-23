import QtQuick
import QtQuick.Controls
import Wflow

// Variant 1 — TIMELINE
// Horizontal pipeline. Each action is a node; a line runs through them.
// Scrolls sideways. Playhead animates across nodes during a run.
Item {
    id: root
    property var actions: []
    property int activeStepIndex: -1
    property bool running: false

    implicitHeight: 260

    ScrollView {
        anchors.fill: parent
        contentHeight: availableHeight
        contentWidth: pipeline.width
        clip: true

        Item {
            id: pipeline
            width: Math.max(root.width, root.actions.length * 200 + 80)
            height: 220
            y: 20

            // Connecting line
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                x: 40
                width: parent.width - 80
                height: 2
                radius: 1
                color: Theme.lineSoft
            }

            // Progress overlay on the line
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                x: 40
                width: root.activeStepIndex >= 0
                    ? ((root.activeStepIndex + 1) / Math.max(1, root.actions.length)) * (parent.width - 80)
                    : 0
                height: 2
                radius: 1
                color: Theme.accent
                Behavior on width { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
            }

            Row {
                anchors.verticalCenter: parent.verticalCenter
                x: 40
                spacing: (parent.width - 80 - (root.actions.length * 44)) / Math.max(1, root.actions.length - 1)

                Repeater {
                    model: root.actions
                    delegate: Item {
                        id: node
                        width: 44
                        height: 180
                        readonly property bool isActive: model.index === root.activeStepIndex
                        readonly property bool isPast: model.index < root.activeStepIndex
                        readonly property color catColor: {
                            const t = ({
                                "key": Theme.catKey, "type": Theme.catType, "click": Theme.catClick,
                                "move": Theme.catMove, "scroll": Theme.catScroll, "focus": Theme.catFocus,
                                "wait": Theme.catWait, "shell": Theme.catShell, "notify": Theme.catNotify,
                                "clipboard": Theme.catClip, "note": Theme.catNote
                            })
                            return t[modelData.kind] || Theme.catWait
                        }

                        // Label above
                        Column {
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: icon.top
                            anchors.bottomMargin: 14
                            spacing: 2
                            width: 140
                            Text {
                                text: String(model.index + 1).padStart(2, "0")
                                color: node.isActive ? node.catColor : Theme.text3
                                font.family: Theme.familyMono
                                font.pixelSize: 10
                                horizontalAlignment: Text.AlignHCenter
                                width: parent.width
                            }
                            Text {
                                text: modelData.summary
                                color: Theme.text
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontXs
                                font.weight: Font.DemiBold
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                                width: parent.width
                            }
                        }

                        // Node
                        Rectangle {
                            id: icon
                            anchors.centerIn: parent
                            width: node.isActive ? 48 : 36
                            height: width
                            radius: width / 2
                            color: node.isActive
                                ? node.catColor
                                : Qt.rgba(node.catColor.r, node.catColor.g, node.catColor.b, node.isPast ? 0.55 : 0.18)
                            border.color: Qt.rgba(node.catColor.r, node.catColor.g, node.catColor.b, node.isActive ? 1.0 : 0.5)
                            border.width: node.isActive ? 2 : 1
                            Behavior on width { NumberAnimation { duration: Theme.durBase; easing.type: Easing.OutCubic } }
                            Behavior on color { ColorAnimation { duration: Theme.durBase } }

                            Text {
                                anchors.centerIn: parent
                                text: {
                                    const g = ({
                                        "key": "⌘", "type": "T", "click": "◉", "move": "↔", "scroll": "⇅",
                                        "focus": "⊡", "wait": "⏱", "shell": "›", "notify": "◐",
                                        "clipboard": "⎘", "note": "¶"
                                    })
                                    return g[modelData.kind] || "•"
                                }
                                color: node.isActive ? Theme.accentText : node.catColor
                                font.family: Theme.familyBody
                                font.pixelSize: node.isActive ? 20 : 16
                                font.weight: Font.Bold
                            }

                            // Pulse when active
                            Rectangle {
                                visible: node.isActive
                                anchors.centerIn: parent
                                width: parent.width + 16
                                height: parent.height + 16
                                radius: width / 2
                                color: "transparent"
                                border.color: node.catColor
                                border.width: 2
                                opacity: 0.6
                                SequentialAnimation on opacity {
                                    running: node.isActive
                                    loops: Animation.Infinite
                                    NumberAnimation { to: 0.15; duration: 900; easing.type: Easing.InOutSine }
                                    NumberAnimation { to: 0.6;  duration: 900; easing.type: Easing.InOutSine }
                                }
                            }
                        }

                        // Value chip below
                        Rectangle {
                            visible: modelData.value && modelData.value.length > 0
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.top: icon.bottom
                            anchors.topMargin: 14
                            width: Math.min(160, valText.implicitWidth + 16)
                            height: 22
                            radius: 11
                            color: Qt.rgba(node.catColor.r, node.catColor.g, node.catColor.b, 0.12)
                            border.color: Qt.rgba(node.catColor.r, node.catColor.g, node.catColor.b, 0.3)
                            border.width: 1

                            Text {
                                id: valText
                                anchors.centerIn: parent
                                text: modelData.value
                                color: node.catColor
                                font.family: Theme.familyMono
                                font.pixelSize: 10
                                elide: Text.ElideRight
                                width: parent.width - 12
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }
                }
            }
        }
    }
}
