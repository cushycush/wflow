import QtQuick
import QtQuick.Controls
import Wflow

// Variant 5 — COMPACT
// Dense 5-col grid, small tiles. Raycast/launcher vibe.
// Icon + title + step count only. Subtitle revealed on hover as tooltip-like overlay.
Flow {
    id: root
    property var workflows: []
    signal openWorkflow(string id)

    spacing: 10

    Repeater {
        model: root.workflows
        delegate: Rectangle {
            id: tile
            readonly property color catColor: {
                const k = modelData.kinds && modelData.kinds.length > 0 ? modelData.kinds[0] : "wait"
                const t = ({
                    "key": Theme.catKey, "type": Theme.catType, "click": Theme.catClick,
                    "move": Theme.catMove, "scroll": Theme.catScroll, "focus": Theme.catFocus,
                    "wait": Theme.catWait, "shell": Theme.catShell, "notify": Theme.catNotify,
                    "clipboard": Theme.catClip, "note": Theme.catNote
                })
                return t[k] || Theme.catWait
            }
            width: (root.width - 10 * 4) / 5
            height: 92
            radius: Theme.radiusMd
            color: tArea.containsMouse ? Theme.surface2 : Theme.surface
            border.color: tArea.containsMouse
                ? Qt.rgba(catColor.r, catColor.g, catColor.b, 0.55)
                : Theme.lineSoft
            border.width: 1
            Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

            MouseArea {
                id: tArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openWorkflow(modelData.id)
            }

            Column {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                Row {
                    width: parent.width
                    spacing: 8

                    CategoryIcon {
                        kind: modelData.kinds && modelData.kinds.length > 0 ? modelData.kinds[0] : "wait"
                        size: 26
                        hovered: tArea.containsMouse
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        text: modelData.steps
                        color: tile.catColor
                        font.family: Theme.familyMono
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.Bold
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 26 - 8
                        horizontalAlignment: Text.AlignRight
                    }
                }

                Text {
                    text: modelData.title
                    color: Theme.text
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    lineHeight: 1.2
                    width: parent.width
                }
            }
        }
    }
}
