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

    readonly property int collapsedW: 80
    readonly property int expandedW: 220

    // Three-letter codes that read at the rail's narrow width. Default
    // to the kind itself when no abbreviation is registered so a new
    // step kind still renders something legible without code changes.
    function _shortFor(kind) {
        switch (kind) {
        case "key":       return "key"
        case "type":      return "txt"
        case "click":     return "clk"
        case "move":      return "mov"
        case "scroll":    return "scr"
        case "focus":     return "fcs"
        case "wait":      return "wt"
        case "shell":     return "sh"
        case "notify":    return "ntf"
        case "clipboard": return "clp"
        case "when":      return "if"
        case "unless":    return "if!"
        case "repeat":    return "rep"
        case "use":       return "use"
        }
        return kind
    }

    implicitWidth: dock.width
    implicitHeight: dock.height

    Rectangle {
        id: dock
        anchors.centerIn: parent
        // Chip MouseAreas swallow QHoverEvents from a dock-level
        // HoverHandler. Each chip bumps chipHoverCount instead.
        property int chipHoverCount: 0
        property bool anyChipDragging: false
        // Mouse moving from one chip to the next briefly drops
        // chipHoverCount to 0; without this latch the dock's width
        // animation flips collapsed-then-expanded mid-traversal and
        // chips visibly judder. Latch holds the expanded state for
        // one animation duration after every "left a chip" event.
        property bool _hoverLatch: false
        Timer {
            id: hoverLatchTimer
            interval: Theme.dur(Theme.durBase) + 80
            repeat: false
            onTriggered: dock._hoverLatch = false
        }
        onChipHoverCountChanged: {
            if (chipHoverCount === 0) {
                _hoverLatch = true
                hoverLatchTimer.restart()
            } else {
                _hoverLatch = false
                hoverLatchTimer.stop()
            }
        }
        readonly property bool isHovered:
            dockHover.hovered || chipHoverCount > 0 || anyChipDragging || _hoverLatch
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
                        delegate: Item {
                            id: chip
                            width: dock.width - 14
                            height: 38
                            anchors.horizontalCenter: parent.horizontalCenter
                            readonly property color catColor: Theme.catFor(modelData.kind)

                            // Chip stretches with the dock, no per-chip
                            // width animation: the dock's width Behavior
                            // is already animating, and chaining a second
                            // animation here was what made hover judder.
                            // Collapsed shows a 3-letter code; expanded
                            // swaps in the friendly label.
                            StepChip {
                                id: chipPill
                                kind: modelData.kind
                                overrideLabel: dock.isHovered
                                    ? modelData.label
                                    : root._shortFor(modelData.kind)
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: 4
                                anchors.rightMargin: 4
                                height: 28
                                fontSize: 11
                                opacity: chipArea.dragging ? 0.85 : 1.0
                            }

                            // Tinted halo on hover / drag; sits underneath
                            // the chip so the chip's own border still wins.
                            Rectangle {
                                anchors.fill: chipPill
                                radius: chipPill.radius
                                z: -1
                                color: chipArea.dragging
                                    ? Qt.rgba(chip.catColor.r, chip.catColor.g, chip.catColor.b, 0.30)
                                    : (chipArea.containsMouse
                                        ? Qt.rgba(chip.catColor.r, chip.catColor.g, chip.catColor.b, 0.15)
                                        : "transparent")
                                border.color: chipArea.dragging ? chip.catColor : "transparent"
                                border.width: 1
                                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                                Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
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
