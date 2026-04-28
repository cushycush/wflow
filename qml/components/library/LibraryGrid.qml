import QtQuick
import QtQuick.Controls
import Wflow

// Plain card grid for the local library. No featured hero — that concept
// belongs to Explore, not to a personal workspace.
Item {
    id: root
    property var folders: []
    property var workflows: []
    // Selection mode: in v1 this is a "manage" toggle on the page.
    // When selectMode is true, clicking a card toggles its membership
    // in selectedIds via toggleSelected(id) instead of opening the
    // editor.
    property bool selectMode: false
    property var selectedIds: ({})
    signal openWorkflow(string id)
    signal openFolder(string fullPath)
    signal deleteRequested(string id)
    signal duplicateRequested(string id)
    signal toggleSelected(string id)

    // Auto-column — each column wants ~300px minimum.
    readonly property int cols: Math.max(2, Math.floor(root.width / 300))
    readonly property real gap: 12
    readonly property real cardW: (root.width - gap * (cols - 1)) / cols
    readonly property real cardH: 136

    readonly property int totalItems: (folders ? folders.length : 0) + (workflows ? workflows.length : 0)
    readonly property int rows: Math.ceil(totalItems / cols)
    height: rows * cardH + Math.max(0, rows - 1) * gap

    // (Empty-canvas right-click menu lives on the LibraryPage's
    // page-level MouseArea so it fires for any spot in the visible
    // viewport, not just the area the grid currently fills with
    // cards. LibraryGrid only sizes to its content, so an in-grid
    // MouseArea would miss any clicks below the last row.)

    // Folders sort first so the user lands on them before scrolling
    // into a wall of workflows. Each folder is a tile with the same
    // footprint as a workflow card so the grid stays uniform.
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

            // Drop target — accepts workflow drags. Drops set the
            // workflow's folder to this tile's full path so the
            // .kdl file moves on disk. Fragments / non-workflow
            // drags are filtered by `keys`.
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

                    Rectangle {
                        width: 32; height: 32; radius: Theme.radiusSm
                        anchors.verticalCenter: parent.verticalCenter
                        color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                        border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "▢"
                            color: Theme.accent
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

            // Grid x/y as bindings so resnap-after-drag is just a
            // re-binding of the same expressions. Workflows render
            // AFTER all folders so we offset by folders.length.
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
            // Internal keeps the drag inside the app — the LibraryPage
            // folder rail picks it up.
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
                    // Drag.dragType: Drag.Internal needs an explicit
                    // Drag.drop() to fire the DropArea's onDropped —
                    // mouse-release on its own only flips
                    // Drag.active back to false and the drop is lost.
                    // Call drop() before restoring the grid bindings
                    // so the folder rail's DropArea sees the source
                    // item.
                    if (drag.active) {
                        card.Drag.drop()
                    }
                    // drag.target moves card.x / card.y away from the
                    // grid bindings. Whether the drop landed on a
                    // folder or not, restore the bindings so the
                    // card snaps back to its grid slot. (If the drop
                    // moved the workflow into another folder it'll
                    // be filtered out of this view on the next
                    // refresh and the delegate will be torn down,
                    // making this a no-op.)
                    card.x = Qt.binding(() => card.gridX)
                    card.y = Qt.binding(() => card.gridY)
                }
            }

            // Selection checkmark, shown only in selectMode. Sits in
            // the top-left so it doesn't fight the kebab menu in the
            // top-right.
            Rectangle {
                visible: root.selectMode
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.topMargin: 8
                anchors.leftMargin: 8
                width: 22; height: 22; radius: 11
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
