import QtQuick
import QtQuick.Controls
import Wflow

// Variant 0 — GRID RICH
// 3-col cards with category-tinted bg, big circular icon, kind row, metadata.
Flow {
    id: root
    property var workflows: []
    signal openWorkflow(string id)
    signal runWorkflow(string id)

    spacing: 16

    Repeater {
        model: root.workflows
        delegate: Rectangle {
            id: card
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

            width: (root.width - 16 * 2) / 3
            height: 168
            radius: Theme.radiusMd

            color: {
                const c = catColor
                const a = cardArea.containsMouse ? 0.12 : 0.06
                return Qt.rgba(c.r, c.g, c.b, a)
            }
            border.color: cardArea.containsMouse
                ? Qt.rgba(catColor.r, catColor.g, catColor.b, 0.45)
                : Theme.lineSoft
            border.width: 1
            Behavior on color { ColorAnimation { duration: Theme.durFast } }
            Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

            MouseArea {
                id: cardArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openWorkflow(modelData.id)
            }

            // Big icon top-right
            CategoryIcon {
                kind: modelData.kinds && modelData.kinds.length > 0 ? modelData.kinds[0] : "wait"
                size: 44
                hovered: cardArea.containsMouse
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: 16
                anchors.rightMargin: 16
            }

            Column {
                anchors.fill: parent
                anchors.margins: 18
                anchors.rightMargin: 72
                spacing: 6

                Text {
                    text: modelData.title
                    color: Theme.text
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontMd
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                    width: parent.width
                }
                Text {
                    text: modelData.subtitle
                    color: Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    lineHeight: 1.35
                    wrapMode: Text.Wrap
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    width: parent.width
                }
            }

            // Bottom: kind pills + meta
            Row {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: 18
                anchors.rightMargin: 18
                anchors.bottomMargin: 14
                spacing: 6

                Repeater {
                    model: (modelData.kinds || []).slice(0, 4)
                    delegate: Rectangle {
                        readonly property color kc: {
                            const t = ({
                                "key": Theme.catKey, "type": Theme.catType, "click": Theme.catClick,
                                "move": Theme.catMove, "scroll": Theme.catScroll, "focus": Theme.catFocus,
                                "wait": Theme.catWait, "shell": Theme.catShell, "notify": Theme.catNotify,
                                "clipboard": Theme.catClip, "note": Theme.catNote
                            })
                            return t[modelData] || Theme.catWait
                        }
                        width: dot.width + 16
                        height: 20
                        radius: 10
                        color: Qt.rgba(kc.r, kc.g, kc.b, 0.18)
                        border.color: Qt.rgba(kc.r, kc.g, kc.b, 0.3)
                        border.width: 1
                        Text {
                            id: dot
                            anchors.centerIn: parent
                            text: modelData
                            color: kc
                            font.family: Theme.familyMono
                            font.pixelSize: 10
                            font.weight: Font.DemiBold
                        }
                    }
                }

            }

            // Right-aligned meta at bottom
            Text {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.rightMargin: 18
                anchors.bottomMargin: 14
                text: modelData.steps + " · " + modelData.lastRun
                color: Theme.text3
                font.family: Theme.familyMono
                font.pixelSize: 10
            }
        }
    }
}
