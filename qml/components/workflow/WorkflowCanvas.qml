import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Shapes
import Wflow

// Node-graph view of a workflow's steps. Renders one card per step in
// a vertical stack; cyan Bezier wires connect each node's bottom port
// to the next node's top port. Selection state is shared with the
// list view via `selectedIndex` so clicking a node still drives the
// existing right-side inspector.
//
// Today: linear top-down layout, no manual node positioning. Flow-
// control kinds (when, unless, repeat) render as a single "fork"
// node with the inner-step count summarized; expanding them inline
// is v0.5 territory.
Item {
    id: root

    property var actions: []
    property int selectedIndex: 0
    property var stepStatuses: ({})

    signal selectStep(int index)

    // Layout constants. Single node = 224x108 with 36px gap; the
    // first node also leaves room for the trigger card if present.
    readonly property int nodeW: 240
    readonly property int nodeH: 110
    readonly property int gap: 36
    readonly property int paddingTop: 36
    readonly property int paddingBottom: 60

    readonly property int contentH: paddingTop
        + actions.length * nodeH
        + Math.max(0, actions.length - 1) * gap
        + paddingBottom

    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: Math.max(height, root.contentH)
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        // Subtle dot grid — same trick as the prototype, drawn via a
        // tiled Image generated from a Canvas at startup. For v1 we
        // approximate with a Repeater that lays out 1px dots; it
        // chews a few hundred draw calls but the scene is small.
        Item {
            id: gridLayer
            anchors.fill: parent
            z: 0

            // Pre-rendered dot grid via a Canvas. Cheaper than a
            // Repeater and resamples cleanly when the canvas is
            // resized.
            Canvas {
                id: dotGrid
                anchors.fill: parent
                onPaint: {
                    const ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    ctx.fillStyle = Theme.isDark
                        ? Qt.rgba(1, 1, 1, 0.05)
                        : Qt.rgba(0, 0, 0, 0.05)
                    const step = 28
                    for (let y = 4; y < height; y += step) {
                        for (let x = 4; x < width; x += step) {
                            ctx.fillRect(x, y, 1.5, 1.5)
                        }
                    }
                }
                Component.onCompleted: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
            }
        }

        // Wires layer — drawn UNDER nodes so the cards visually float
        // above the connector lines.
        Item {
            id: wireLayer
            anchors.fill: parent
            z: 1

            Repeater {
                model: Math.max(0, root.actions.length - 1)
                delegate: Shape {
                    readonly property real centerX: parent.width / 2
                    readonly property real fromY: root.paddingTop + (index + 1) * root.nodeH + index * root.gap
                    readonly property real toY: fromY + root.gap

                    anchors.fill: parent
                    smooth: true
                    layer.enabled: true
                    layer.samples: 4

                    ShapePath {
                        strokeColor: Qt.rgba(0.55, 0.78, 0.88, 0.7)
                        strokeWidth: 1.5
                        fillColor: "transparent"
                        startX: centerX
                        startY: fromY
                        PathCubic {
                            x: centerX; y: toY
                            control1X: centerX; control1Y: fromY + (toY - fromY) * 0.5
                            control2X: centerX; control2Y: fromY + (toY - fromY) * 0.5
                        }
                    }

                    // Arrowhead — small triangle anchored at toY.
                    ShapePath {
                        strokeColor: "transparent"
                        fillColor: Qt.rgba(0.55, 0.78, 0.88, 0.85)
                        startX: centerX - 4
                        startY: toY - 2
                        PathLine { x: centerX + 4; y: toY - 2 }
                        PathLine { x: centerX; y: toY + 4 }
                        PathLine { x: centerX - 4; y: toY - 2 }
                    }
                }
            }
        }

        // Nodes layer.
        Repeater {
            model: root.actions

            delegate: Item {
                width: parent.width
                height: root.nodeH
                z: 2

                readonly property bool isSelected: model.index === root.selectedIndex
                readonly property bool isActive: false   // engine-active step; wire later
                readonly property var act: modelData
                readonly property string kind: modelData ? modelData.kind : "wait"
                readonly property color cardBg:
                    isSelected ? Theme.surface2 : Theme.surface
                readonly property string status: {
                    const s = root.stepStatuses
                    if (!s) return ""
                    const v = s[model.index]
                    return v === undefined ? "" : v
                }

                // Stack nodes vertically with the configured gap.
                y: root.paddingTop + model.index * (root.nodeH + root.gap)

                Rectangle {
                    id: card
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.nodeW
                    height: root.nodeH - 4
                    radius: 14
                    color: cardBg
                    border.color: isSelected
                        ? Qt.rgba(0.55, 0.78, 0.88, 0.9)
                        : (cardArea.containsMouse ? Theme.line : Theme.lineSoft)
                    border.width: isSelected ? 2 : 1

                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    Behavior on y { NumberAnimation { duration: Theme.dur(Theme.durFast); easing.type: Theme.easingStd } }

                    layer.enabled: true
                    layer.effect: MultiEffect {
                        shadowEnabled: true
                        shadowColor: Theme.shadowColor
                        shadowBlur: cardArea.containsMouse ? 1.0 : 0.7
                        shadowVerticalOffset: cardArea.containsMouse ? 12 : 8
                    }

                    MouseArea {
                        id: cardArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectStep(model.index)
                    }

                    Column {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 8

                        // Header row: KIND label, step number, status dot.
                        Row {
                            width: parent.width
                            spacing: 8

                            Text {
                                text: card.parent.kind.toUpperCase()
                                color: Theme.text3
                                font.family: Theme.familyBody
                                font.pixelSize: 10
                                font.weight: Font.Bold
                                font.letterSpacing: 1.4
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width
                                    - numBadge.width
                                    - statusDot.width
                                    - parent.spacing * 2
                                elide: Text.ElideRight
                            }

                            Rectangle {
                                id: numBadge
                                width: numText.implicitWidth + 14
                                height: 18
                                radius: 9
                                color: Theme.bg
                                border.color: Theme.lineSoft
                                border.width: 1
                                anchors.verticalCenter: parent.verticalCenter
                                Text {
                                    id: numText
                                    anchors.centerIn: parent
                                    text: String(model.index + 1).padStart(2, "0")
                                    color: Theme.text3
                                    font.family: Theme.familyMono
                                    font.pixelSize: 10
                                }
                            }

                            Rectangle {
                                id: statusDot
                                anchors.verticalCenter: parent.verticalCenter
                                width: 7; height: 7; radius: 3.5
                                color: card.parent.status === "ok"      ? Theme.ok
                                    :  card.parent.status === "error"   ? Theme.err
                                    :  card.parent.status === "skipped" ? Theme.text3
                                    :  Theme.lineSoft
                            }
                        }

                        // Action body — gradient pill carrying the
                        // primary value. Falls back to a generic "step"
                        // label for flow-control kinds since they have
                        // no single primary string.
                        GradientPill {
                            kind: card.parent.kind
                            text: _summary(card.parent.act)
                            icon: Theme.catGlyph(card.parent.kind)
                            width: parent.width
                        }
                    }
                }
            }
        }
    }

    // Squash the action down to a one-liner suitable for the pill.
    // A real implementation would reuse the engine's describe() but
    // we don't have a QML-side mirror of that yet; this is enough to
    // make the canvas legible in the meantime.
    function _summary(act) {
        if (!act) return ""
        switch (act.kind) {
        case "key":       return act.chord || "(empty chord)"
        case "type":      return (act.text || "").slice(0, 32) || "(empty)"
        case "click":     return "button " + (act.button !== undefined ? act.button : 1)
        case "mouse-down":
        case "mouse-up":  return "button " + (act.button !== undefined ? act.button : 1)
        case "key-down":
        case "key-up":    return act.chord || ""
        case "move":      return "(" + (act.x || 0) + ", " + (act.y || 0) + ")"
        case "scroll":    return "dx " + (act.dx || 0) + "  dy " + (act.dy || 0)
        case "focus":     return act.name || ""
        case "wait-window": return (act.name || "") + "  ·  " + (act.timeout_ms || 0) + "ms"
        case "wait":      return (act.ms || 0) + " ms"
        case "shell":     return (act.command || "").slice(0, 32) || "(empty)"
        case "notify":    return act.title || ""
        case "clipboard": return (act.text || "").slice(0, 28) || ""
        case "note":      return (act.text || "").slice(0, 28) || ""
        case "repeat":    return "× " + (act.count || 1) + " · " + (act.steps ? act.steps.length : 0) + " steps"
        case "when":
        case "unless":    return (act.steps ? act.steps.length : 0) + " inner steps"
        }
        return ""
    }
}
