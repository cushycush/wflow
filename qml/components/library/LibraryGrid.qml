import QtQuick
import QtQuick.Controls
import Wflow

Item {
    id: root
    property var folders: []
    property var workflows: []
    property bool selectMode: false
    property var selectedIds: ({})
    signal openWorkflow(string id)
    signal openFolder(string fullPath)
    signal deleteRequested(string id)
    signal duplicateRequested(string id)
    signal toggleSelected(string id)

    readonly property int cols: Math.max(2, Math.floor(root.width / 300))
    readonly property real gap: 12
    readonly property real cardW: (root.width - gap * (cols - 1)) / cols
    readonly property real cardH: 136

    readonly property int totalItems: (folders ? folders.length : 0) + (workflows ? workflows.length : 0)
    readonly property int rows: Math.ceil(totalItems / cols)
    height: rows * cardH + Math.max(0, rows - 1) * gap

    Repeater {
        id: folderRep
        model: root.folders
        delegate: Rectangle {
            id: folderTile
            readonly property var fld: modelData
            readonly property real gridX: (index % root.cols) * (root.cardW + root.gap)
            readonly property real gridY: Math.floor(index / root.cols) * (root.cardH + root.gap)

            x: gridX
            y: gridY
            width: root.cardW
            height: root.cardH
            radius: Theme.radiusMd
            color: folderArea.containsMouse || folderDrop.containsDrag
                ? Theme.surface2
                : Theme.surface
            border.color: folderDrop.containsDrag
                ? Theme.accent
                : (folderArea.containsMouse ? Theme.line : Theme.lineSoft)
            border.width: folderDrop.containsDrag ? 2 : 1
            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
            Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

            DropArea {
                id: folderDrop
                anchors.fill: parent
                keys: ["wflow/workflow-id"]
                onDropped: (drop) => {
                    const src = drop.source
                    const id = (src && src.wf) ? src.wf.id : ""
                    if (!id) return
                    libCtrl.set_folder(id, folderTile.fld.fullPath)
                    drop.accept()
                }
            }

            MouseArea {
                id: folderArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: (mouse) => {
                    if (mouse.button === Qt.RightButton) {
                        folderMenu.popup()
                    } else {
                        root.openFolder(folderTile.fld.fullPath)
                    }
                }
            }

            WfMenu {
                id: folderMenu
                WfMenuItem {
                    text: "Open"
                    onTriggered: root.openFolder(folderTile.fld.fullPath)
                }
            }

            Column {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 10

                Row {
                    spacing: 10
                    width: parent.width

                    // Folders use a quieter neutral palette so the
                    // workflow icons (amber) hold the brand color.
                    // Folders are organizational containers — they
                    // recede; the workflows inside them are the
                    // content the user came for.
                    Rectangle {
                        width: 32; height: 32; radius: Theme.radiusSm
                        anchors.verticalCenter: parent.verticalCenter
                        color: Theme.wash(Theme.text2, 0.18)
                        border.color: Theme.wash(Theme.text2, 0.45)
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "▢"
                            color: Theme.text2
                            font.family: Theme.familyBody
                            font.pixelSize: 16
                            font.weight: Font.DemiBold
                        }
                    }

                    Column {
                        width: parent.width - 32 - 10
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        Text {
                            text: folderTile.fld.name
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontBase
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            width: parent.width
                        }
                        Text {
                            text: "folder"
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontXs
                            elide: Text.ElideRight
                            width: parent.width
                        }
                    }
                }
            }
        }
    }

    Repeater {
        model: root.workflows
        delegate: Rectangle {
            id: card
            readonly property var wf: modelData
            readonly property color catColor: Theme.catFor(
                wf.kinds && wf.kinds.length > 0 ? wf.kinds[0] : "wait")

            // Grid pos as bindings: resnap-after-drag is a re-bind.
            // Offset by folders.length since folders render first.
            readonly property int totalIndex: index + (root.folders ? root.folders.length : 0)
            readonly property real gridX: (totalIndex % root.cols) * (root.cardW + root.gap)
            readonly property real gridY: Math.floor(totalIndex / root.cols) * (root.cardH + root.gap)

            x: gridX
            y: gridY
            width: root.cardW
            height: root.cardH
            radius: Theme.radiusMd
            color: cardArea.containsMouse ? Theme.surface2 : Theme.surface
            border.color: cardArea.containsMouse
                ? Theme.wash(catColor, 0.42)
                : Theme.lineSoft
            border.width: 1
            opacity: cardArea.drag.active ? 0.55 : 1
            z: cardArea.drag.active ? 10 : 0
            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
            Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
            Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durFast) } }

            // Drag payload: workflow id + a "Workflow" key so folder-
            // row DropAreas can filter for it specifically. dragType
            // Internal keeps the drag inside the app, the LibraryPage
            // folder rail picks it up.
            //
            // Drag.hotSpot is the point on the dragged tile that
            // the cursor is "holding." DropAreas use the hotSpot to
            // decide whether the drag is over them, so a centered
            // hotSpot means clicks at the bottom of the card register
            // as drags from the card's middle, folders highlight by
            // card-center, not cursor. We update the hotSpot on press
            // (below, in the MouseArea) so it tracks the actual click
            // point. Initial values still have to be valid for the
            // very first press where onPressed hasn't fired yet.
            Drag.active: cardArea.drag.active
            Drag.dragType: Drag.Internal
            Drag.keys: ["wflow/workflow-id"]
            Drag.hotSpot.x: card.width / 2
            Drag.hotSpot.y: card.height / 2
            Drag.mimeData: { "wflow/workflow-id": wf.id }

            activeFocusOnTab: true
            Keys.onReturnPressed: root.openWorkflow(card.wf.id)
            Keys.onEnterPressed:  root.openWorkflow(card.wf.id)
            Keys.onSpacePressed:  root.openWorkflow(card.wf.id)
            Keys.onMenuPressed:   cardMenu.popup()
            Keys.onDeletePressed: root.deleteRequested(card.wf.id)
            FocusRing { }

            readonly property bool selected: root.selectedIds[card.wf.id] === true

            MouseArea {
                id: cardArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                drag.target: card
                drag.threshold: 8
                // Snap hotSpot to the click point so drop detection
                // follows the cursor, not the card centre.
                onPressed: (mouse) => {
                    card.Drag.hotSpot.x = mouse.x
                    card.Drag.hotSpot.y = mouse.y
                }
                onClicked: (mouse) => {
                    card.forceActiveFocus()
                    if (mouse.button === Qt.RightButton) {
                        cardMenu.popup()
                    } else if (root.selectMode) {
                        root.toggleSelected(card.wf.id)
                    } else {
                        root.openWorkflow(card.wf.id)
                    }
                }
                onReleased: {
                    // Drag.Internal needs explicit drop() before bindings
                    // restore; release alone loses the drop event.
                    if (drag.active) {
                        card.Drag.drop()
                    }
                    card.x = Qt.binding(() => card.gridX)
                    card.y = Qt.binding(() => card.gridY)
                }
            }

            Rectangle {
                visible: root.selectMode
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.topMargin: 8
                anchors.leftMargin: 8
                width: 22; height: 22; radius: Theme.radiusSm
                color: card.selected ? Theme.err : Theme.surface3
                border.color: card.selected ? Theme.err : Theme.line
                border.width: 1
                Text {
                    visible: card.selected
                    anchors.centerIn: parent
                    text: "✓"
                    color: "white"
                    font.family: Theme.familyBody
                    font.pixelSize: 13
                    font.weight: Font.Bold
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

            WfMenu {
                id: cardMenu
                WfMenuItem {
                    text: "Duplicate"
                    onTriggered: root.duplicateRequested(card.wf.id)
                }
                WfMenuItem {
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

                    // Library cards lead with the workflow mark (a
                    // brand-amber stair-step) so workflows are
                    // recognizable as workflows, not as their first
                    // step. The category-icon row below still shows
                    // which kinds the workflow uses.
                    WorkflowIcon {
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

                    readonly property int kindsCount: card.wf.kinds ? card.wf.kinds.length : 0
                    readonly property int kindsCap: 6
                    readonly property int kindsShown: Math.min(kindsCount, kindsCap)
                    readonly property int kindsHidden: Math.max(0, kindsCount - kindsCap)

                    Repeater {
                        model: (card.wf.kinds || []).slice(0, parent.kindsCap)
                        delegate: CategoryIcon {
                            kind: modelData
                            size: 20
                            hovered: false
                        }
                    }

                    // "+N" pill shows that more steps exist beyond the
                    // visible fingerprint, so a 14-step workflow doesn't
                    // overflow the card or pretend it has 6 steps.
                    Rectangle {
                        visible: parent.kindsHidden > 0
                        width: moreText.implicitWidth + 10
                        height: 20
                        radius: 10
                        anchors.verticalCenter: parent.verticalCenter
                        color: "transparent"
                        border.color: Theme.lineSoft
                        border.width: 1

                        Text {
                            id: moreText
                            anchors.centerIn: parent
                            text: "+" + parent.parent.kindsHidden
                            color: Theme.text3
                            font.family: Theme.familyMono
                            font.pixelSize: 10
                        }
                    }

                    Item { width: Math.max(0, parent.width
                            - parent.kindsShown * 20
                            - Math.max(0, parent.kindsShown - 1) * 6
                            - (parent.kindsHidden > 0 ? 30 : 0)
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
