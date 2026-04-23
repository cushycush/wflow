import QtQuick
import QtQuick.Controls
import Wflow

// Dense row list. Good for users with many workflows. The drag handle on the
// left shows up on hover — reorder wiring lands in a follow-up; the visual
// affordance is here so the intent reads.
Column {
    id: root
    property var workflows: []
    signal openWorkflow(string id)

    spacing: 0

    Repeater {
        model: root.workflows
        delegate: Rectangle {
            id: row
            readonly property var wf: modelData
            readonly property color catColor: {
                const k = wf.kinds && wf.kinds.length > 0 ? wf.kinds[0] : "wait"
                const t = ({
                    "key": Theme.catKey, "type": Theme.catType, "click": Theme.catClick,
                    "move": Theme.catMove, "scroll": Theme.catScroll, "focus": Theme.catFocus,
                    "wait": Theme.catWait, "shell": Theme.catShell, "notify": Theme.catNotify,
                    "clipboard": Theme.catClip, "note": Theme.catNote
                })
                return t[k] || Theme.catWait
            }

            width: root.width
            height: 52
            color: rowArea.containsMouse ? Theme.surface2 : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.durFast } }

            // Hairline
            Rectangle {
                height: 1
                color: Theme.lineSoft
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                visible: index < root.workflows.length - 1
            }

            MouseArea {
                id: rowArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openWorkflow(row.wf.id)
            }

            Row {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 20
                spacing: 14

                // Drag handle — visible only on hover, placeholder for reorder wiring.
                Item {
                    width: 16
                    height: parent.height
                    opacity: rowArea.containsMouse ? 0.8 : 0
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                    Text {
                        anchors.centerIn: parent
                        text: "⋮⋮"
                        color: Theme.text3
                        font.pixelSize: 14
                        font.family: Theme.familyBody
                    }
                }

                CategoryIcon {
                    kind: row.wf.kinds && row.wf.kinds.length > 0 ? row.wf.kinds[0] : "wait"
                    size: 28
                    hovered: rowArea.containsMouse
                    anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                    width: (parent.width - 16 - 14 - 28 - 14 - kindRow.width - 14 - stepsText.width - 14 - runsText.width - 14 - lastRunText.width - 14) / 1
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1

                    Text {
                        text: row.wf.title
                        color: Theme.text
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        width: parent.width
                    }
                    Text {
                        text: row.wf.subtitle
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontXs
                        elide: Text.ElideRight
                        width: parent.width
                    }
                }

                Row {
                    id: kindRow
                    spacing: 4
                    anchors.verticalCenter: parent.verticalCenter
                    Repeater {
                        model: (row.wf.kinds || []).slice(0, 4)
                        delegate: CategoryIcon {
                            kind: modelData
                            size: 18
                            hovered: false
                        }
                    }
                }

                Text {
                    id: stepsText
                    text: row.wf.steps + " steps"
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: Theme.fontXs
                    anchors.verticalCenter: parent.verticalCenter
                    width: 62
                    horizontalAlignment: Text.AlignRight
                }

                Text {
                    id: runsText
                    text: row.wf.runs + " runs"
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: Theme.fontXs
                    anchors.verticalCenter: parent.verticalCenter
                    width: 60
                    horizontalAlignment: Text.AlignRight
                }

                Text {
                    id: lastRunText
                    text: row.wf.lastRun
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: Theme.fontXs
                    anchors.verticalCenter: parent.verticalCenter
                    width: 100
                    horizontalAlignment: Text.AlignRight
                }
            }
        }
    }
}
