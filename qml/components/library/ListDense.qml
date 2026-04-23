import QtQuick
import QtQuick.Controls
import Wflow

// Variant 1 — LIST DENSE
// Vertical list. Icon left, title/subtitle center, step/run meta right.
Column {
    id: root
    property var workflows: []
    signal openWorkflow(string id)

    spacing: 4

    Repeater {
        model: root.workflows
        delegate: Rectangle {
            id: row
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
            width: root.width
            height: 64
            radius: Theme.radiusMd
            color: rowArea.containsMouse ? Theme.surface2 : "transparent"
            border.color: rowArea.containsMouse ? Theme.lineSoft : "transparent"
            border.width: 1
            Behavior on color { ColorAnimation { duration: Theme.durFast } }

            MouseArea {
                id: rowArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openWorkflow(modelData.id)
            }

            Row {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 18
                spacing: 16

                CategoryIcon {
                    kind: modelData.kinds && modelData.kinds.length > 0 ? modelData.kinds[0] : "wait"
                    size: 36
                    hovered: rowArea.containsMouse
                    anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 36 - 16 - metaBlock.width - 16
                    spacing: 3

                    Text {
                        text: modelData.title
                        color: Theme.text
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontBase
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        width: parent.width
                    }
                    Text {
                        text: modelData.subtitle
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        elide: Text.ElideRight
                        width: parent.width
                    }
                }

                // Meta column at right
                Row {
                    id: metaBlock
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 24

                    // Kind strip
                    Row {
                        spacing: 4
                        anchors.verticalCenter: parent.verticalCenter
                        Repeater {
                            model: (modelData.kinds || []).slice(0, 5)
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
                                width: 8; height: 8; radius: 4
                                color: kc
                            }
                        }
                    }

                    Text {
                        text: modelData.steps + " step" + (modelData.steps === 1 ? "" : "s")
                        color: Theme.text2
                        font.family: Theme.familyMono
                        font.pixelSize: Theme.fontXs
                        anchors.verticalCenter: parent.verticalCenter
                        width: 60
                        horizontalAlignment: Text.AlignRight
                    }
                    Text {
                        text: modelData.lastRun
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontXs
                        anchors.verticalCenter: parent.verticalCenter
                        width: 90
                        horizontalAlignment: Text.AlignRight
                    }
                    Text {
                        text: "›"
                        color: rowArea.containsMouse ? Theme.accent : Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: 20
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            // Bottom divider (subtle — full 1px border, not a left stripe)
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: Theme.lineSoft
                visible: !rowArea.containsMouse && (index < (root.workflows.length - 1))
            }
        }
    }
}
