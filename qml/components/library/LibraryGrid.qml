import QtQuick
import QtQuick.Controls
import Wflow

// Plain card grid for the local library. No featured hero — that concept
// belongs to Explore, not to a personal workspace.
Item {
    id: root
    property var folders: []
    property var workflows: []
    // The page passes the FILTERED workflows in `workflows` (only items
    // in the current folder). Folder tiles need the full list so they
    // can show how many workflows live inside each subfolder.
    property var allWorkflows: []
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
    // EXPERIMENT: bumped from 136 to fit the wflows.com hero-card
    // rhythm (avatar + title-block + run pill + description + step
    // trail + ruled footer).
    readonly property real cardH: 200

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
            // Folder tiles run on a slightly darker surface step so they
            // recede from workflow cards while still living in the same
            // grid. The tab decoration on top (folderTab below) does the
            // actual "this is a folder" lifting.
            radius: Theme.radiusLg
            color: folderArea.containsMouse || folderDrop.containsDrag
                ? Theme.surface3
                : Theme.surface2
            border.color: folderDrop.containsDrag
                ? Theme.accent
                : (folderArea.containsMouse ? Theme.lineStrong : Theme.line)
            border.width: folderDrop.containsDrag ? 2 : 1
            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
            Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

            // How many workflows live in this folder. Computed from the
            // sibling workflows array so it stays accurate without a
            // round-trip to libCtrl. Matches the LibraryPage tree's
            // count semantics.
            readonly property int wfCount: {
                if (!root.allWorkflows) return 0
                let n = 0
                for (let i = 0; i < root.allWorkflows.length; ++i) {
                    if (root.allWorkflows[i].folder === folderTile.fld.fullPath) n++
                }
                return n
            }

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

            // ── Folder tab decoration ──
            // A small rounded rectangle pinned to the top edge,
            // overhanging the body's top border by a few pixels so it
            // reads as a tab sticking up from a folder. The body's
            // border still runs unbroken behind the tab; the tab paints
            // its own fill and border on top, with a 1px sliver at the
            // bottom that overlaps the body to mask the seam.
            Rectangle {
                id: folderTab
                z: 1
                anchors.top: parent.top
                anchors.topMargin: -7
                anchors.left: parent.left
                anchors.leftMargin: 18
                width: 72
                height: 14
                radius: 4
                color: parent.color
                border.color: parent.border.color
                border.width: 1
                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                // 1px tall mask at the very bottom of the tab, painted
                // in the body's fill color, so the seam between tab
                // and body disappears and they read as one folder
                // shape.
                Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 1
                    anchors.rightMargin: 1
                    height: 1
                    color: folderTile.color
                }
            }

            Column {
                anchors.fill: parent
                anchors.topMargin: 18
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                anchors.bottomMargin: 16
                spacing: 10

                // Folder glyph + name on a single row, scaled so the
                // tile reads as a real folder icon at a glance.
                Row {
                    spacing: 12
                    width: parent.width

                    Rectangle {
                        width: 40
                        height: 32
                        radius: 6
                        anchors.verticalCenter: parent.verticalCenter
                        color: Theme.wash(Theme.text2, 0.16)
                        border.color: Theme.wash(Theme.text2, 0.36)
                        border.width: 1

                        // Tiny tab on the icon glyph itself, mirroring
                        // the card-level tab so the icon reads as a
                        // folder even when scanned in peripheral view.
                        Rectangle {
                            anchors.bottom: parent.top
                            anchors.bottomMargin: -2
                            anchors.left: parent.left
                            anchors.leftMargin: 4
                            width: 14
                            height: 5
                            radius: 2
                            color: parent.color
                            border.color: parent.border.color
                            border.width: 1
                        }
                    }

                    Column {
                        width: parent.width - 40 - 12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        Text {
                            text: folderTile.fld.name
                            color: Theme.text
                            font.family: Theme.familyDisplay
                            font.pixelSize: Theme.fontBase
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            width: parent.width
                        }
                        Text {
                            text: folderTile.wfCount === 1
                                ? "1 workflow"
                                : folderTile.wfCount + " workflows"
                            color: Theme.text3
                            font.family: Theme.familyMono
                            font.pixelSize: 10
                            font.letterSpacing: 0.4
                            elide: Text.ElideRight
                            width: parent.width
                        }
                    }
                }
            }

            // Mono "FOLDER" label kicker in the bottom-left, matching
            // the editorial small-caps register that surrounds the
            // workflow card's "N STEPS" footer.
            Text {
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.bottomMargin: 14
                anchors.leftMargin: 16
                text: "FOLDER"
                color: Theme.text3
                font.family: Theme.familyMono
                font.pixelSize: 9
                font.letterSpacing: 0.6
                font.weight: Font.DemiBold
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
            radius: Theme.radiusLg
            color: cardArea.containsMouse ? Theme.surface2 : Theme.surface
            border.color: cardArea.containsMouse ? Theme.lineStrong : Theme.line
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
            //
            // Drag.hotSpot is the point on the dragged tile that
            // the cursor is "holding." DropAreas use the hotSpot to
            // decide whether the drag is over them, so a centered
            // hotSpot means clicks at the bottom of the card register
            // as drags from the card's middle — folders highlight by
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
                // Snap Drag.hotSpot to the actual click point so drop
                // detection follows the cursor rather than the card's
                // geometric center. Without this, a click at the
                // bottom of the card has its drag-over highlight
                // anchored to the middle of the card, which makes
                // small drop targets (folder rail rows) feel
                // unreachable from anywhere except the card's centre.
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

            // EXPERIMENT: layout mirrors the wflows.com hero-card
            // rhythm — avatar + title-block + open-pill on top, a
            // description block, then the step-trail, then a ruled
            // footer with meta on the left and an imported badge on
            // the right. Replaces the prior icon + title / kinds row
            // / footer layout. Right-click still surfaces the
            // duplicate / delete menu (kebab affordance dropped).
            Item {
                anchors.fill: parent

                // ── Top row: avatar + title-block + open-pill ──
                Item {
                    id: topRow
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.topMargin: 16
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    height: 36

                    Avatar {
                        id: monoAvatar
                        // Title drives both the monogram letter and the
                        // gradient hash. The letter being the workflow's
                        // first character is the meaningful signal — the
                        // gradient drifting on rename is a fair trade.
                        handle: card.wf.title
                        size: 32
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        anchors.left: monoAvatar.right
                        anchors.leftMargin: 10
                        anchors.right: openPill.left
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        Text {
                            text: card.wf.title
                            color: Theme.text
                            font.family: Theme.familyDisplay
                            font.pixelSize: Theme.fontBase
                            font.weight: Font.DemiBold
                            font.letterSpacing: -0.2
                            elide: Text.ElideRight
                            width: parent.width
                        }
                        Text {
                            text: card.wf.importedFrom
                                ? "from @" + card.wf.importedFrom
                                : "by you"
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: 10
                            elide: Text.ElideRight
                            width: parent.width
                        }
                    }

                    // Pill mirror of wflows.com's "Open in wflow" CTA.
                    // Click does the same thing the whole card does,
                    // just with a deliberate accent on hover.
                    Rectangle {
                        id: openPill
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: openText.implicitWidth + 22
                        height: 26
                        radius: height / 2
                        color: openArea.containsMouse ? Theme.accent : Theme.surface2
                        border.color: openArea.containsMouse ? Theme.accent : Theme.line
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                        Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                        Text {
                            id: openText
                            anchors.centerIn: parent
                            text: "↗  Open"
                            color: openArea.containsMouse ? Theme.accentText : Theme.text2
                            font.family: Theme.familyBody
                            font.pixelSize: 10
                            font.weight: Font.DemiBold
                            font.letterSpacing: 0.4
                            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                        }

                        MouseArea {
                            id: openArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.openWorkflow(card.wf.id)
                        }
                    }
                }

                // ── Description (subtitle as its own block) ──
                Text {
                    id: descText
                    anchors.top: topRow.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.topMargin: 12
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    text: card.wf.subtitle
                    color: Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    lineHeight: 1.35
                    visible: text.length > 0
                }

                // ── Step trail (wflows.com chip preview) ──
                // Shared with the explore catalog cards. Hover state
                // forwards from the card so chips stagger in left to
                // right when the user mouses over a workflow.
                StepChipTrail {
                    id: trailRow
                    anchors.top: descText.visible ? descText.bottom : topRow.bottom
                    anchors.topMargin: 12
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    trail: {
                        if (!card.wf) return []
                        if (card.wf.trail && card.wf.trail.length > 0) return card.wf.trail
                        const k = card.wf.kinds || []
                        return k.map(kind => ({ kind: kind, value: "" }))
                    }
                    hovered: cardArea.containsMouse
                }

                // ── Footer with rule: meta left, imported badge right ──
                Rectangle {
                    id: footerRule
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: footerRow.top
                    anchors.bottomMargin: 10
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    height: 1
                    color: Theme.lineSoft
                }

                Item {
                    id: footerRow
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottomMargin: 14
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    height: 14

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        Text {
                            text: card.wf.steps + " STEPS"
                            color: Theme.text2
                            font.family: Theme.familyMono
                            font.pixelSize: 9
                            font.letterSpacing: 0.6
                            font.weight: Font.DemiBold
                        }
                        Text {
                            text: "·"
                            color: Theme.text3
                            font.family: Theme.familyMono
                            font.pixelSize: 9
                        }
                        Text {
                            text: card.wf.lastRun
                            color: Theme.text3
                            font.family: Theme.familyMono
                            font.pixelSize: 9
                            font.letterSpacing: 0.4
                        }
                    }

                    Rectangle {
                        visible: !!card.wf.importedFrom
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: importedText.implicitWidth + 12
                        height: 16
                        radius: 8
                        color: "transparent"
                        border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.4)
                        border.width: 1
                        Text {
                            id: importedText
                            anchors.centerIn: parent
                            text: card.wf.importedFrom ? "↑ @" + card.wf.importedFrom : ""
                            color: Theme.accent
                            font.family: Theme.familyMono
                            font.pixelSize: 9
                            font.letterSpacing: 0.3
                        }
                    }
                }
            }
        }
    }
}
