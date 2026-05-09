import QtQuick
import QtQuick.Controls
import Wflow

// Drag is manual (not Drag/DropArea) so the canvas can render a real
// card-shaped preview ghost instead of a system drag cursor.
Item {
    id: root
    property var canvas: null

    // Input / effect / flow groups, separated by dividers.
    readonly property var _categories: [
        { kinds: [
            { kind: "key",       label: "Press key" },
            { kind: "type",      label: "Type text" },
            { kind: "click",     label: "Mouse click" },
            { kind: "move",      label: "Move cursor" },
            { kind: "scroll",    label: "Scroll" }
        ]},
        { kinds: [
            { kind: "focus",     label: "Focus window" },
            { kind: "wait",      label: "Wait" },
            { kind: "shell",     label: "Shell command" },
            { kind: "notify",    label: "Notify" },
            { kind: "clipboard", label: "Clipboard" }
        ]},
        { kinds: [
            { kind: "when",      label: "When (conditional)" },
            { kind: "unless",    label: "Unless (conditional)" },
            { kind: "repeat",    label: "Repeat block" },
            { kind: "use",       label: "Use named import" }
        ]}
    ]

    readonly property int collapsedW: 56
    readonly property int expandedW: 200

    implicitWidth: dock.width
    implicitHeight: dock.height

    Rectangle {
        id: dock
        anchors.centerIn: parent
        // Chip MouseAreas swallow QHoverEvents from a dock-level
        // HoverHandler. Each chip bumps chipHoverCount instead.
        property int chipHoverCount: 0
        property bool anyChipDragging: false
        readonly property bool isHovered:
            dockHover.hovered || chipHoverCount > 0 || anyChipDragging
        width: isHovered ? root.expandedW : root.collapsedW
        height: stack.implicitHeight + 16
        radius: Theme.radiusMd
        color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.94)
        border.color: Theme.lineSoft
        border.width: 1
        Behavior on width {
            NumberAnimation { duration: Theme.dur(Theme.durBase); easing.type: Easing.OutCubic }
        }

        HoverHandler {
            id: dockHover
            margin: 8
        }

        Column {
            id: stack
            anchors.centerIn: parent
            spacing: 4

            Repeater {
                model: root._categories
                delegate: Column {
                    spacing: 2

                    Item {
                        visible: model.index > 0
                        width: dock.width - 14
                        height: 11
                        anchors.horizontalCenter: parent.horizontalCenter
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 4
                            anchors.rightMargin: 4
                            height: 1
                            color: Theme.lineSoft
                        }
                    }

                    Repeater {
                        model: modelData.kinds
                        delegate: Rectangle {
                            id: chip
                            width: dock.width - 14
                            height: 42
                            anchors.horizontalCenter: parent.horizontalCenter
                            radius: Theme.radiusSm
                            readonly property color catColor: Theme.catFor(modelData.kind)
                            readonly property bool expanded: dock.isHovered
                            color: chipArea.dragging
                                ? Qt.rgba(catColor.r, catColor.g, catColor.b, 0.30)
                                : (chipArea.containsMouse
                                    ? Qt.rgba(catColor.r, catColor.g, catColor.b, 0.15)
                                    : "transparent")
                            border.color: chipArea.dragging
                                ? catColor
                                : "transparent"
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                            Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                            CategoryIcon {
                                id: chipIcon
                                x: 9  // fixed so labels align across chips
                                anchors.verticalCenter: parent.verticalCenter
                                kind: modelData.kind
                                size: 24
                                hovered: chipArea.containsMouse || chipArea.dragging
                            }

                            Text {
                                anchors.left: chipIcon.right
                                anchors.leftMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                visible: chip.expanded
                                opacity: chip.expanded ? 1.0 : 0.0
                                Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durFast) } }
                                text: modelData.label
                                color: chip.catColor
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontSm
                                font.weight: Font.Medium
                            }

                            MouseArea {
                                id: chipArea
                                anchors.fill: parent
                                hoverEnabled: true
                                // preventStealing: canvas pan would
                                // otherwise grab the drag past the
                                // motion threshold.
                                preventStealing: true
                                cursorShape: dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                property bool dragging: false

                                onContainsMouseChanged: {
                                    dock.chipHoverCount = Math.max(
                                        0,
                                        dock.chipHoverCount + (containsMouse ? 1 : -1))
                                }
                                onDraggingChanged: dock.anyChipDragging = dragging

                                onPressed: (mouse) => {
                                    if (!root.canvas) return
                                    const scene = chip.mapToItem(null, mouse.x, mouse.y)
                                    dragging = true
                                    root.canvas.previewDrag(modelData.kind, scene.x, scene.y)
                                }
                                onPositionChanged: (mouse) => {
                                    if (!dragging || !root.canvas) return
                                    const scene = chip.mapToItem(null, mouse.x, mouse.y)
                                    root.canvas.moveDragPreview(scene.x, scene.y)
                                }
                                onReleased: (mouse) => {
                                    if (!dragging) return
                                    dragging = false
                                    if (root.canvas) {
                                        const scene = chip.mapToItem(null, mouse.x, mouse.y)
                                        root.canvas.endDragPreview(scene.x, scene.y, true)
                                    }
                                }
                                onCanceled: {
                                    if (dragging) {
                                        dragging = false
                                        if (root.canvas) root.canvas.endDragPreview(0, 0, false)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
