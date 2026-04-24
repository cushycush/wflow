import QtQuick
import QtQuick.Controls
import Wflow

// Plain card grid for the local library. No featured hero — that concept
// belongs to Explore, not to a personal workspace.
Item {
    id: root
    property var workflows: []
    signal openWorkflow(string id)
    signal deleteRequested(string id)
    signal duplicateRequested(string id)

    // Auto-column — each column wants ~300px minimum.
    readonly property int cols: Math.max(2, Math.floor(root.width / 300))
    readonly property real gap: 12
    readonly property real cardW: (root.width - gap * (cols - 1)) / cols
    readonly property real cardH: 136

    readonly property int rows: Math.ceil(workflows.length / cols)
    height: rows * cardH + Math.max(0, rows - 1) * gap

    Repeater {
        model: root.workflows
        delegate: Rectangle {
            id: card
            readonly property var wf: modelData
            readonly property color catColor: Theme.catFor(
                wf.kinds && wf.kinds.length > 0 ? wf.kinds[0] : "wait")

            x: (index % root.cols) * (root.cardW + root.gap)
            y: Math.floor(index / root.cols) * (root.cardH + root.gap)
            width: root.cardW
            height: root.cardH
            radius: Theme.radiusMd
            color: cardArea.containsMouse ? Theme.surface2 : Theme.surface
            border.color: cardArea.containsMouse
                ? Theme.wash(catColor, 0.42)
                : Theme.lineSoft
            border.width: 1
            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
            Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

            MouseArea {
                id: cardArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: (mouse) => {
                    if (mouse.button === Qt.RightButton) cardMenu.popup()
                    else root.openWorkflow(card.wf.id)
                }
            }

            // ⋯ affordance, visible on hover so right-click isn't the only
            // discoverable path to the context menu.
            Rectangle {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: 6
                anchors.rightMargin: 6
                width: 24; height: 24; radius: 4
                color: moreArea.containsMouse ? Theme.surface3 : "transparent"
                opacity: cardArea.containsMouse || moreArea.containsMouse ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.durFast } }
                Text {
                    anchors.centerIn: parent
                    text: "⋯"
                    color: Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: 16
                }
                MouseArea {
                    id: moreArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: cardMenu.popup()
                }
            }

            Menu {
                id: cardMenu
                MenuItem {
                    text: "Duplicate"
                    onTriggered: root.duplicateRequested(card.wf.id)
                }
                MenuItem {
                    text: "Delete"
                    onTriggered: root.deleteRequested(card.wf.id)
                }
            }

            Column {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 10

                Row {
                    spacing: 10
                    width: parent.width

                    CategoryIcon {
                        kind: card.wf.kinds && card.wf.kinds.length > 0 ? card.wf.kinds[0] : "wait"
                        size: 32
                        hovered: cardArea.containsMouse
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        width: parent.width - 32 - 10
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        Text {
                            text: card.wf.title
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontBase
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            width: parent.width
                        }
                        Text {
                            text: card.wf.subtitle
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontXs
                            elide: Text.ElideRight
                            width: parent.width
                        }
                    }
                }

                Row {
                    spacing: 6
                    width: parent.width

                    Repeater {
                        model: card.wf.kinds || []
                        delegate: CategoryIcon {
                            kind: modelData
                            size: 20
                            hovered: false
                        }
                    }

                    Item { width: Math.max(0, parent.width
                            - (card.wf.kinds ? card.wf.kinds.length : 0) * 20
                            - Math.max(0, (card.wf.kinds ? card.wf.kinds.length : 0) - 1) * 6
                            - (card.wf.importedFrom ? importedPill.width + 6 : 0))
                          height: 1 }

                    // Imported-from pill, subtle accent outline so the user
                    // can tell a workflow came from Explore at a glance.
                    Rectangle {
                        id: importedPill
                        visible: !!card.wf.importedFrom
                        width: importedText.implicitWidth + 12
                        height: 20
                        radius: 10
                        anchors.verticalCenter: parent.verticalCenter
                        color: "transparent"
                        border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.4)
                        border.width: 1

                        Text {
                            id: importedText
                            anchors.centerIn: parent
                            text: card.wf.importedFrom ? "@" + card.wf.importedFrom : ""
                            color: Theme.accent
                            font.family: Theme.familyMono
                            font.pixelSize: 10
                        }
                    }
                }

                Item { width: 1; height: parent.height - 32 - 10 - 20 - 10 - 14 }

                Row {
                    spacing: 8
                    width: parent.width

                    Text {
                        text: card.wf.steps + " steps"
                        color: Theme.text3
                        font.family: Theme.familyMono
                        font.pixelSize: 10
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Rectangle {
                        width: 2; height: 2; radius: 1
                        color: Theme.text3
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: card.wf.lastRun
                        color: Theme.text3
                        font.family: Theme.familyMono
                        font.pixelSize: 10
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }
    }
}
