import QtQuick
import QtQuick.Controls
import Wflow

Item {
    id: root
    property var folders: []
    property var workflows: []
    // workflows is filtered to current folder; allWorkflows is needed
    // for folder tiles' counts.
    property var allWorkflows: []
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
    // Reserves vertical budget for the chip trail's +N badge case.
    readonly property real cardH: 220

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

            readonly property int wfCount: {
                if (!root.allWorkflows) return 0
                let n = 0
                for (let i = 0; i < root.allWorkflows.length; ++i) {
                    if (root.allWorkflows[i].folder === folderTile.fld.fullPath) n++
                }
                return n
            }

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

                // 1px sliver in body fill masks the tab/body seam.
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

            // Grid pos as bindings: resnap-after-drag is a re-bind.
            // Offset by folders.length since folders render first.
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
            // rhythm, avatar + title-block + open-pill on top, a
            // description block, then the step-trail, then a ruled
            // footer with meta on the left and an imported badge on
            // the right. Replaces the prior icon + title / kinds row
            // / footer layout. Right-click still surfaces the
            // duplicate / delete menu (kebab affordance dropped).
            Item {
                anchors.fill: parent

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
