import QtQuick
import QtQuick.Controls
import Wflow

// Variant 4 — CARDS
// Each action as a full-width card. Step number is huge, category icon big,
// value in a code block. Heavier, more presentational.
Column {
    id: root
    property var actions: []
    property int activeStepIndex: -1
    property bool running: false

    spacing: 12

    Repeater {
        model: root.actions
        delegate: Rectangle {
            id: card
            readonly property bool isActive: model.index === root.activeStepIndex
            readonly property color catColor: {
                const t = ({
                    "key": Theme.catKey, "type": Theme.catType, "click": Theme.catClick,
                    "move": Theme.catMove, "scroll": Theme.catScroll, "focus": Theme.catFocus,
                    "wait": Theme.catWait, "shell": Theme.catShell, "notify": Theme.catNotify,
                    "clipboard": Theme.catClip, "note": Theme.catNote
                })
                return t[modelData.kind] || Theme.catWait
            }

            width: parent.width
            height: 104
            radius: Theme.radiusLg
            color: {
                if (isActive) return Qt.rgba(catColor.r, catColor.g, catColor.b, 0.18)
                return Qt.rgba(catColor.r, catColor.g, catColor.b, cardArea.containsMouse ? 0.10 : 0.05)
            }
            border.color: isActive
                ? catColor
                : (cardArea.containsMouse ? Qt.rgba(catColor.r, catColor.g, catColor.b, 0.4) : Theme.lineSoft)
            border.width: isActive ? 2 : 1
            Behavior on color { ColorAnimation { duration: Theme.durFast } }
            Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

            MouseArea {
                id: cardArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
            }

            Row {
                anchors.fill: parent
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                spacing: 20

                // Huge step number
                Text {
                    text: String(model.index + 1).padStart(2, "0")
                    color: Qt.rgba(card.catColor.r, card.catColor.g, card.catColor.b, 0.6)
                    font.family: Theme.familyMono
                    font.pixelSize: 52
                    font.weight: Font.Bold
                    anchors.verticalCenter: parent.verticalCenter
                    width: 80
                    verticalAlignment: Text.AlignVCenter
                }

                CategoryIcon {
                    kind: modelData.kind
                    size: 56
                    hovered: cardArea.containsMouse
                    anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 80 - 20 - 56 - 20 - 80
                    spacing: 4

                    Row {
                        spacing: 10
                        Text {
                            text: modelData.kind.toUpperCase()
                            color: card.catColor
                            font.family: Theme.familyMono
                            font.pixelSize: 10
                            font.weight: Font.Bold
                            font.letterSpacing: 1.4
                        }
                    }

                    Text {
                        text: modelData.summary
                        color: Theme.text
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontLg
                        font.weight: Font.DemiBold
                    }

                    Text {
                        text: modelData.value
                        color: Theme.text2
                        font.family: Theme.familyMono
                        font.pixelSize: Theme.fontSm
                        elide: Text.ElideRight
                        width: parent.width
                    }
                }

                // Right — status pill
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 72
                    height: 24
                    radius: 12
                    color: card.isActive
                        ? card.catColor
                        : Qt.rgba(card.catColor.r, card.catColor.g, card.catColor.b, 0.15)
                    border.color: Qt.rgba(card.catColor.r, card.catColor.g, card.catColor.b, card.isActive ? 1.0 : 0.3)
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: card.isActive ? "RUNNING" : "ready"
                        color: card.isActive ? Theme.accentText : card.catColor
                        font.family: Theme.familyMono
                        font.pixelSize: 10
                        font.weight: Font.Bold
                    }
                }
            }
        }
    }
}
