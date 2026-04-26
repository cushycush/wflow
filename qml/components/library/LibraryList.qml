import QtQuick
import QtQuick.Controls
import Wflow

// Dense row list with drag-to-reorder. Grab the ⋮⋮ handle on the left of a
// row and drag vertically; on release the row snaps into its new slot and
// the page's workflows array is reordered. Moves are animated via ListView's
// move + displaced transitions so neighbors ease into place.
Item {
    id: root
    property var workflows: []
    property int rowHeight: 52
    signal openWorkflow(string id)
    signal reorderRequested(int from, int to)
    signal deleteRequested(string id)
    signal duplicateRequested(string id)

    height: list.contentHeight

    ListView {
        id: list
        anchors.fill: parent
        model: root.workflows
        interactive: false
        spacing: 0
        clip: false

        move: Transition {
            NumberAnimation { property: "y"; duration: 200; easing.type: Easing.OutCubic }
        }
        displaced: Transition {
            NumberAnimation { property: "y"; duration: 200; easing.type: Easing.OutCubic }
        }

        delegate: Item {
            id: slot
            width: list.width
            height: root.rowHeight

            // Row content — gets detached (drag.target) when the handle is held.
            Rectangle {
                id: card
                readonly property var wf: modelData
                readonly property bool dragging: dragArea.drag.active

                width: parent.width
                height: parent.height
                color: card.dragging
                    ? Theme.surface2
                    : (rowArea.containsMouse ? Theme.surface2 : "transparent")
                border.color: card.dragging ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.5) : "transparent"
                border.width: card.dragging ? 1 : 0
                radius: card.dragging ? Theme.radiusSm : 0
                scale: card.dragging ? 1.01 : 1.0
                opacity: card.dragging ? 0.96 : 1.0
                z: card.dragging ? 2 : 0

                Behavior on color { ColorAnimation { duration: Theme.durFast } }
                Behavior on scale { NumberAnimation { duration: 120 } }
                Behavior on opacity { NumberAnimation { duration: 120 } }

                // Bottom hairline (hidden while dragging for cleanliness)
                Rectangle {
                    height: 1
                    color: Theme.lineSoft
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    visible: index < root.workflows.length - 1 && !card.dragging
                }

                activeFocusOnTab: true
                Keys.onReturnPressed: root.openWorkflow(card.wf.id)
                Keys.onEnterPressed:  root.openWorkflow(card.wf.id)
                Keys.onSpacePressed:  root.openWorkflow(card.wf.id)
                Keys.onMenuPressed:   rowMenu.popup()
                Keys.onDeletePressed: root.deleteRequested(card.wf.id)
                FocusRing { radiusOverride: 4 }

                MouseArea {
                    id: rowArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: (mouse) => {
                        if (card.dragging) return
                        card.forceActiveFocus()
                        if (mouse.button === Qt.RightButton) rowMenu.popup()
                        else root.openWorkflow(card.wf.id)
                    }
                    // Don't swallow events originating on the drag handle.
                    propagateComposedEvents: true
                }

                WfMenu {
                    id: rowMenu
                    WfMenuItem {
                        text: "Duplicate"
                        onTriggered: root.duplicateRequested(card.wf.id)
                    }
                    WfMenuItem {
                        text: "Delete"
                        onTriggered: root.deleteRequested(card.wf.id)
                    }
                }

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 20
                    spacing: 14

                    // Drag handle (only this area initiates a drag)
                    Item {
                        id: dragHandle
                        width: 20
                        height: parent.height
                        opacity: (rowArea.containsMouse || card.dragging) ? 0.9 : 0
                        Behavior on opacity { NumberAnimation { duration: 120 } }

                        Text {
                            anchors.centerIn: parent
                            text: "⋮⋮"
                            color: card.dragging ? Theme.accent : Theme.text3
                            font.pixelSize: 14
                            font.family: Theme.familyBody
                            font.weight: Font.Bold
                        }

                        MouseArea {
                            id: dragArea
                            anchors.fill: parent
                            cursorShape: card.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                            hoverEnabled: true
                            drag.target: card
                            drag.axis: Drag.YAxis
                            drag.minimumY: -slot.y
                            drag.maximumY: list.contentHeight - slot.y - slot.height

                            onReleased: {
                                const delta = Math.round(card.y / root.rowHeight)
                                const target = Math.max(0, Math.min(root.workflows.length - 1, index + delta))
                                card.y = 0                         // snap back first
                                if (target !== index) {
                                    root.reorderRequested(index, target)
                                }
                            }
                        }
                    }

                    CategoryIcon {
                        kind: card.wf.kinds && card.wf.kinds.length > 0 ? card.wf.kinds[0] : "wait"
                        size: 28
                        hovered: rowArea.containsMouse
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        width: Math.max(120, parent.width
                            - 8 - 14                           // outer
                            - 20 - 14                          // handle
                            - 28 - 14                          // icon
                            - kindRow.width - 14
                            - (card.wf.importedFrom ? importedPill.width + 14 : 0)
                            - stepsText.width - 14
                            - runsText.width - 14
                            - lastRunText.width - 14)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        Text {
                            text: card.wf.title
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
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

                    Row {
                        id: kindRow
                        spacing: 4
                        anchors.verticalCenter: parent.verticalCenter
                        Repeater {
                            model: (card.wf.kinds || []).slice(0, 4)
                            delegate: CategoryIcon {
                                kind: modelData
                                size: 18
                                hovered: false
                            }
                        }
                    }

                    Rectangle {
                        id: importedPill
                        visible: !!card.wf.importedFrom
                        width: importedLbl.implicitWidth + 10
                        height: 18
                        radius: 9
                        anchors.verticalCenter: parent.verticalCenter
                        color: "transparent"
                        border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.4)
                        border.width: 1

                        Text {
                            id: importedLbl
                            anchors.centerIn: parent
                            text: card.wf.importedFrom ? "@" + card.wf.importedFrom : ""
                            color: Theme.accent
                            font.family: Theme.familyMono
                            font.pixelSize: 9
                        }
                    }

                    Text {
                        id: stepsText
                        text: card.wf.steps + " steps"
                        color: Theme.text3
                        font.family: Theme.familyMono
                        font.pixelSize: Theme.fontXs
                        anchors.verticalCenter: parent.verticalCenter
                        width: 62
                        horizontalAlignment: Text.AlignRight
                    }

                    Text {
                        id: runsText
                        text: card.wf.runs + " runs"
                        color: Theme.text3
                        font.family: Theme.familyMono
                        font.pixelSize: Theme.fontXs
                        anchors.verticalCenter: parent.verticalCenter
                        width: 60
                        horizontalAlignment: Text.AlignRight
                    }

                    Text {
                        id: lastRunText
                        text: card.wf.lastRun
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
}
