import QtQuick
import QtQuick.Controls
import Wflow

// Vertical icon dock for the canvas — Adobe / Figma style. Stacks
// step-kind icons (input → effect → flow) in a thin column on the
// canvas's left edge. Each icon-only button is a drag source: press
// + drag to canvas drops a new step at the cursor position.
//
// Drag is handled manually (not Drag/DropArea) so we can show a real
// card-shaped preview ghost in the canvas instead of the system drag
// cursor. The button's MouseArea forwards press / move / release with
// scene-coordinate points, and the canvas renders the ghost itself.
//
// Hover any icon to see its kind label as a tooltip; the icon-only
// dock trades label legibility for canvas real estate, and the
// labels reappear on demand without the bottom strip eating screen.
Item {
    id: root
    // The WorkflowCanvas instance to forward drag events to.
    property var canvas: null

    // Three category groups separated by a thin divider in the dock:
    // Input (the wdotool primitives), Effect (out-of-process side
    // effects), and Flow (control structures). Each entry's `label`
    // is what shows up as the hover tooltip.
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

    // Expanded width gives room for the labels next to each icon.
    // Collapsed = icon-only. Hover anywhere in the dock to slide it
    // open; mouse out to slide back. Animation is fast enough not
    // to feel laggy but slow enough to read as motion.
    readonly property int collapsedW: 56
    readonly property int expandedW: 200

    implicitWidth: dock.width
    implicitHeight: dock.height

    Rectangle {
        id: dock
        anchors.centerIn: parent
        width: dockHover.containsMouse ? root.expandedW : root.collapsedW
        height: stack.implicitHeight + 16
        radius: Theme.radiusMd
        color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.94)
        border.color: Theme.lineSoft
        border.width: 1
        Behavior on width {
            NumberAnimation { duration: Theme.dur(Theme.durBase); easing.type: Easing.OutCubic }
        }

        // Hover detection on the entire dock. Drag operations
        // (chipArea.dragging) keep the dock open even after the
        // mouse leaves, so a long drag doesn't see the dock
        // collapse mid-gesture.
        MouseArea {
            id: dockHover
            anchors.fill: parent
            anchors.margins: -8  // forgiving hover bounds
            hoverEnabled: true
            acceptedButtons: Qt.NoButton  // pass clicks through
            propagateComposedEvents: true
        }

        Column {
            id: stack
            anchors.centerIn: parent
            spacing: 4

            Repeater {
                model: root._categories
                delegate: Column {
                    spacing: 2

                    // Thin divider above every category except the
                    // first — visual separator between Input /
                    // Effect / Flow without spending vertical space
                    // on labels.
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
                            // Chip width tracks the dock — when the
                            // dock is expanded the chip stretches
                            // to leave room for the label.
                            width: dock.width - 14
                            height: 42
                            anchors.horizontalCenter: parent.horizontalCenter
                            radius: Theme.radiusSm
                            readonly property color catColor: Theme.catFor(modelData.kind)
                            readonly property bool expanded: dockHover.containsMouse
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
                                x: 9  // fixed left position so labels align
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
                                // Hold the press for the entire drag; the
                                // canvas's pan DragHandler would otherwise
                                // steal the gesture once motion crossed its
                                // threshold and the user would end up
                                // panning the canvas instead of dropping a
                                // chip on it.
                                preventStealing: true
                                cursorShape: dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                property bool dragging: false

                                ToolTip.visible: containsMouse && !dragging
                                ToolTip.delay: 400
                                ToolTip.text: modelData.label

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
