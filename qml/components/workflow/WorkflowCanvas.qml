import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Shapes
import Wflow

// Node-graph view of a workflow's steps. Free-positionable cards on a
// scrollable canvas; cyan Bezier wires trace the execution order
// (steps still run sequentially — wire ordering is bound to the step
// list, not to user-chosen edges).
//
// Three layout modes auto-arrange cards: vertical stack, horizontal
// row, or wrapping grid. Switching modes reflows everything; manual
// drag overrides the auto-layout for that card until the next reflow.
//
// The dot-to-dot rewiring affordance (drag from one card's port to
// another's) is intentionally NOT here yet — it needs a port-drag
// handle protocol that's bigger than this turn. Reordering today
// happens via the rail's ↑/↓ controls.
Item {
    id: root

    property var actions: []
    property int selectedIndex: 0
    property var stepStatuses: ({})
    // "vertical" | "horizontal" | "grid". Drives _autoLayout().
    property string layoutMode: "vertical"
    // { [stepId]: {x, y} } — absolute positions inside the Flickable's
    // contentItem. Set by _autoLayout() on layout/actions changes; user
    // drag overwrites the entry for the dragged card.
    property var positions: ({})

    signal selectStep(int index)
    signal deselectRequested()
    // Emitted when the user drops a palette card on the canvas. The
    // page handles the actual step add (kind → action default) and
    // assigns the new step's position via positions[id] = {x,y}.
    signal addStepAtRequested(string kind, real x, real y)

    readonly property int nodeW: 260
    readonly property int nodeMinH: 132
    readonly property int gap: 36
    readonly property int paddingTop: 36
    readonly property int paddingLeft: 36
    readonly property int paddingBottom: 60

    // Recompute auto-layout positions from scratch for the current
    // mode. Called whenever the action list, layout mode, or canvas
    // size changes (debounced indirectly by Behavior on x/y).
    function _autoLayout() {
        const out = {}
        const list = root.actions || []
        const n = list.length
        if (n === 0) { positions = {}; return }
        const w = flick.width
        if (layoutMode === "vertical") {
            const x = Math.max(paddingLeft, (w - nodeW) / 2)
            for (let i = 0; i < n; i++) {
                out[list[i].id] = { x: x, y: paddingTop + i * (nodeMinH + gap) }
            }
        } else if (layoutMode === "horizontal") {
            for (let i = 0; i < n; i++) {
                out[list[i].id] = { x: paddingLeft + i * (nodeW + gap), y: paddingTop }
            }
        } else {
            // Grid: wrap by canvas width. Always at least one column.
            const cols = Math.max(1, Math.floor((w - paddingLeft) / (nodeW + gap)))
            for (let i = 0; i < n; i++) {
                const col = i % cols
                const row = Math.floor(i / cols)
                out[list[i].id] = {
                    x: paddingLeft + col * (nodeW + gap),
                    y: paddingTop + row * (nodeMinH + gap)
                }
            }
        }
        positions = out
    }

    // Re-run on any of: list changes, mode changes, canvas resize.
    onActionsChanged: _autoLayout()
    onLayoutModeChanged: _autoLayout()
    Component.onCompleted: _autoLayout()

    // Content extent — derived from the rightmost / bottom-most card
    // so horizontal & grid layouts can scroll past the visible area.
    readonly property int contentW: {
        let mx = flick.width
        const list = root.actions || []
        for (let i = 0; i < list.length; i++) {
            const p = positions[list[i].id]
            if (p) mx = Math.max(mx, p.x + nodeW + paddingLeft)
        }
        return mx
    }
    readonly property int contentH: {
        let my = flick.height
        const list = root.actions || []
        for (let i = 0; i < list.length; i++) {
            const p = positions[list[i].id]
            if (p) my = Math.max(my, p.y + nodeMinH + paddingBottom)
        }
        return my
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: root.contentW
        contentHeight: root.contentH
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        onWidthChanged: root._autoLayout()

        // Empty-area click → deselect. Cards' own MouseAreas are at
        // higher z so they win their hits.
        MouseArea {
            anchors.fill: parent
            z: 0
            onClicked: root.deselectRequested()
        }

        // Drop target for palette drags — when a kind chip is dropped
        // here we ask the page to add a step at the drop coordinate.
        DropArea {
            anchors.fill: parent
            keys: ["wflow/kind"]
            onDropped: (drop) => {
                const kind = drop.getDataAsString("wflow/kind")
                if (kind && kind.length > 0) {
                    root.addStepAtRequested(kind, drop.x, drop.y)
                    drop.accept()
                }
            }
        }

        // Wires layer — drawn UNDER the cards.
        Item {
            id: wireLayer
            anchors.fill: parent
            z: 1

            Repeater {
                model: Math.max(0, (root.actions || []).length - 1)
                delegate: Shape {
                    readonly property var fromCard: nodeRep.itemAt(index)
                    readonly property var toCard: nodeRep.itemAt(index + 1)

                    // Source / target ports depend on layout mode so wires
                    // exit the side that points toward the next card.
                    readonly property real sourceX: fromCard
                        ? (root.layoutMode === "horizontal"
                            ? (fromCard.x + fromCard.width)
                            : (fromCard.x + fromCard.width / 2))
                        : 0
                    readonly property real sourceY: fromCard
                        ? (root.layoutMode === "horizontal"
                            ? (fromCard.y + fromCard.height / 2)
                            : (fromCard.y + fromCard.height))
                        : 0
                    readonly property real targetX: toCard
                        ? (root.layoutMode === "horizontal"
                            ? toCard.x
                            : (toCard.x + toCard.width / 2))
                        : 0
                    readonly property real targetY: toCard
                        ? (root.layoutMode === "horizontal"
                            ? (toCard.y + toCard.height / 2)
                            : toCard.y)
                        : 0

                    anchors.fill: parent
                    smooth: true
                    layer.enabled: true
                    layer.samples: 4

                    ShapePath {
                        strokeColor: Qt.rgba(0.55, 0.78, 0.88, 0.7)
                        strokeWidth: 1.5
                        fillColor: "transparent"
                        startX: sourceX
                        startY: sourceY
                        // Cubic control points: pulled along the layout's
                        // primary axis so the curve eases out cleanly
                        // regardless of which mode we're in.
                        PathCubic {
                            x: targetX; y: targetY
                            control1X: root.layoutMode === "horizontal"
                                ? (sourceX + (targetX - sourceX) / 2) : sourceX
                            control1Y: root.layoutMode === "horizontal"
                                ? sourceY : (sourceY + (targetY - sourceY) / 2)
                            control2X: root.layoutMode === "horizontal"
                                ? (sourceX + (targetX - sourceX) / 2) : targetX
                            control2Y: root.layoutMode === "horizontal"
                                ? targetY : (sourceY + (targetY - sourceY) / 2)
                        }
                    }

                    // Arrowhead at the target end. Rotated to track the
                    // tangent of the curve as it lands.
                    ShapePath {
                        strokeColor: "transparent"
                        fillColor: Qt.rgba(0.55, 0.78, 0.88, 0.85)
                        startX: targetX - (root.layoutMode === "horizontal" ? 6 : 4)
                        startY: targetY - (root.layoutMode === "horizontal" ? 4 : 6)
                        PathLine {
                            x: targetX + (root.layoutMode === "horizontal" ? -6 : 4)
                            y: targetY + (root.layoutMode === "horizontal" ? 4 : -6)
                        }
                        PathLine { x: targetX; y: targetY }
                        PathLine {
                            x: targetX - (root.layoutMode === "horizontal" ? 6 : 4)
                            y: targetY - (root.layoutMode === "horizontal" ? 4 : 6)
                        }
                    }
                }
            }
        }

        // Nodes layer — each card is positioned absolutely from the
        // positions map so drag and auto-layout can both write into
        // the same channel.
        Repeater {
            id: nodeRep
            model: root.actions

            delegate: Item {
                id: cardItem
                width: root.nodeW
                height: card.height
                z: dragArea.drag.active ? 100 : 2

                readonly property bool isSelected: model.index === root.selectedIndex
                readonly property var act: modelData
                readonly property string stepId: modelData ? modelData.id : ""
                readonly property string kind: modelData ? modelData.kind : "wait"
                readonly property color cardBg:
                    isSelected ? Theme.surface2 : Theme.surface
                readonly property string status: {
                    const s = root.stepStatuses
                    if (!s) return ""
                    const v = s[model.index]
                    return v === undefined ? "" : v
                }

                // Pull initial position from the positions map. Once
                // the user drags, the binding breaks and we manage x/y
                // by hand; _syncFromPositions() reattaches when the
                // map changes externally (layout switch, action add).
                function _syncFromPositions() {
                    const p = root.positions[stepId]
                    if (p) { x = p.x; y = p.y }
                }
                Component.onCompleted: _syncFromPositions()
                Connections {
                    target: root
                    function onPositionsChanged() { cardItem._syncFromPositions() }
                }

                Behavior on x {
                    enabled: !dragArea.drag.active
                    NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Theme.easingStd }
                }
                Behavior on y {
                    enabled: !dragArea.drag.active
                    NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Theme.easingStd }
                }

                Rectangle {
                    id: card
                    width: parent.width
                    height: Math.max(root.nodeMinH - 4, cardBody.implicitHeight + 24)
                    radius: 14
                    color: cardItem.cardBg
                    border.color: cardItem.isSelected
                        ? Qt.rgba(0.55, 0.78, 0.88, 0.9)
                        : (dragArea.containsMouse ? Theme.line : Theme.lineSoft)
                    border.width: cardItem.isSelected ? 2 : 1

                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    Behavior on height { NumberAnimation { duration: Theme.dur(Theme.durFast); easing.type: Theme.easingStd } }

                    layer.enabled: true
                    layer.effect: MultiEffect {
                        shadowEnabled: true
                        shadowColor: Theme.shadowColor
                        shadowBlur: dragArea.containsMouse || dragArea.drag.active ? 1.0 : 0.7
                        shadowVerticalOffset: dragArea.drag.active ? 18 : (dragArea.containsMouse ? 12 : 8)
                    }

                    MouseArea {
                        id: dragArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: dragArea.drag.active ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                        // drag.target is the cardItem so dragging moves
                        // the wrapper Item that the wires read from.
                        drag.target: cardItem
                        drag.axis: Drag.XAndYAxis
                        drag.threshold: 4

                        property bool _wasDragged: false
                        onPressed: _wasDragged = false
                        onPositionChanged: if (drag.active) _wasDragged = true
                        onReleased: {
                            if (_wasDragged) {
                                // Persist the new position; drop into a
                                // fresh map so the property change fires
                                // and other cards' Connections can resync.
                                const next = Object.assign({}, root.positions)
                                next[cardItem.stepId] = { x: cardItem.x, y: cardItem.y }
                                root.positions = next
                            } else {
                                root.selectStep(model.index)
                            }
                        }
                    }

                    Column {
                        id: cardBody
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        anchors.topMargin: 12
                        spacing: 8

                        Row {
                            width: parent.width
                            spacing: 8

                            Text {
                                text: cardItem.kind.toUpperCase()
                                color: Theme.text3
                                font.family: Theme.familyBody
                                font.pixelSize: 10
                                font.weight: Font.Bold
                                font.letterSpacing: 1.4
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - numBadge.width - statusDot.width - parent.spacing * 2
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
                                color: cardItem.status === "ok"      ? Theme.ok
                                    :  cardItem.status === "error"   ? Theme.err
                                    :  cardItem.status === "skipped" ? Theme.text3
                                    :  Theme.lineSoft
                            }
                        }

                        GradientPill {
                            kind: cardItem.kind
                            text: _pillText(cardItem.act)
                            icon: Theme.catGlyph(cardItem.kind)
                            width: parent.width
                        }

                        Flow {
                            spacing: 6
                            visible: chipModel.length > 0
                            width: parent.width
                            readonly property var chipModel:
                                _chipsFor(cardItem.act ? cardItem.act.rawAction : null,
                                          cardItem.act)
                            Repeater {
                                model: parent.chipModel
                                delegate: Rectangle {
                                    height: 18
                                    width: chipText.implicitWidth + 12
                                    radius: 9
                                    color: Theme.surface3
                                    border.color: Theme.lineSoft
                                    border.width: 1
                                    Text {
                                        id: chipText
                                        anchors.centerIn: parent
                                        text: modelData
                                        color: Theme.text2
                                        font.family: Theme.familyMono
                                        font.pixelSize: 9
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ============== Floating UI ==============

    // Layout-mode picker — top-right corner, three icons.
    Rectangle {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 8
        anchors.rightMargin: 8
        z: 50
        width: layoutRow.implicitWidth + 8
        height: 32
        radius: 8
        color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.92)
        border.color: Theme.lineSoft
        border.width: 1

        Row {
            id: layoutRow
            anchors.centerIn: parent
            spacing: 2

            Repeater {
                model: [
                    { id: "vertical",   glyph: "≡",  tip: "Vertical stack" },
                    { id: "horizontal", glyph: "‖",  tip: "Horizontal row" },
                    { id: "grid",       glyph: "▦",  tip: "Wrapping grid" }
                ]
                delegate: Rectangle {
                    readonly property bool isOn: root.layoutMode === modelData.id
                    width: 28; height: 26; radius: 6
                    anchors.verticalCenter: parent.verticalCenter
                    color: isOn
                        ? Theme.accentWash(0.16)
                        : (lmArea.containsMouse ? Theme.surface2 : "transparent")
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                    Text {
                        anchors.centerIn: parent
                        text: modelData.glyph
                        color: parent.isOn ? Theme.accent : Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: 14
                        font.weight: parent.isOn ? Font.DemiBold : Font.Medium
                    }
                    MouseArea {
                        id: lmArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.layoutMode = modelData.id
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: modelData.tip
                    }
                }
            }
        }
    }

    // ============== Helpers ==============

    function _chipsFor(act, shaped) {
        const out = []
        if (!shaped) return out
        if (shaped.enabled === false) out.push("skipped")
        if (shaped.onError === "continue") out.push("on err: continue")
        if (!act) return out
        if (act.delay_ms !== undefined && act.delay_ms !== null) out.push("⏱ " + act.delay_ms + "ms")
        if (act.retries !== undefined && act.retries !== null && act.retries > 0) out.push("↻ " + act.retries + "×")
        if (act.backoff_ms !== undefined && act.backoff_ms !== null) out.push("backoff " + act.backoff_ms + "ms")
        if (act.timeout_ms !== undefined && act.timeout_ms !== null) out.push("timeout " + act.timeout_ms + "ms")
        if (act.clear_modifiers === true) out.push("clear mods")
        return out
    }

    function _pillText(shaped) {
        if (!shaped) return ""
        const s = shaped.editable
            ? (shaped.rawPrimary || "")
            : (shaped.value || "")
        if (!s) return "(empty)"
        return s.length > 36 ? s.slice(0, 36) + "…" : s
    }
}
