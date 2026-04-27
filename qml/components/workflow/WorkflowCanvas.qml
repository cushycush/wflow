import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Shapes
import Wflow

// Free-positioning node editor for a workflow.
//
// Cards live at absolute (x, y) inside the Flickable's contentItem
// and are persisted in the `positions` map keyed by step.id. Wires
// auto-route between consecutive steps in the linear sequence,
// picking exit/entry sides per pair based on geometry — there's no
// sticky layout mode that fights the user's drags.
//
// The three "Organize" buttons in the top-right are one-shot
// commands: clicking re-arranges every card once into the chosen
// shape. Otherwise positions are sticky — opening / closing the
// inspector, adding a step from the rail, or resizing the window
// will not reflow anything. New steps from the rail are placed at
// the bottom of the existing layout; new steps from a palette drag
// land where the user dropped them.
//
// Each card carries four port dots on its edges. Dragging from any
// dot to another card reorders the sequence so the dragged-from
// card becomes the immediate predecessor of the dropped-on card.
// (Wires still represent linear execution order — the dots are a
// visual rewire, not a graph edge.)
Item {
    id: root

    property var actions: []
    property int selectedIndex: 0
    property var stepStatuses: ({})

    // Reactive position / height stores. Each card writes into these
    // on drag-release and on height-change; wires read from them.
    property var positions: ({})    // { [id]: {x, y} }
    property var cardHeights: ({})  // { [id]: number }

    signal selectStep(int index)
    signal deselectRequested()
    signal addStepAtRequested(string kind, real x, real y)
    // Rewire from a card's overflow menu — `stepIndex` is the card
    // that's being rewired, `otherIndex` is the chosen counterpart.
    // The page resolves these via _moveStep.
    signal predecessorChosen(int stepIndex, int otherIndex)
    signal successorChosen(int stepIndex, int otherIndex)

    readonly property int nodeW: 260
    readonly property int nodeMinH: 132
    readonly property int gap: 36
    readonly property int paddingTop: 36
    readonly property int paddingLeft: 36
    readonly property int paddingBottom: 60

    // ============ Layout actions (one-shot) ============

    function organizeVertical() {
        const list = root.actions || []
        const next = {}
        const x = Math.max(paddingLeft, (flick.width - nodeW) / 2)
        let y = paddingTop
        for (let i = 0; i < list.length; i++) {
            next[list[i].id] = { x: x, y: y }
            y += (cardHeights[list[i].id] || nodeMinH) + gap
        }
        positions = next
    }
    function organizeHorizontal() {
        const list = root.actions || []
        const next = {}
        let x = paddingLeft
        for (let i = 0; i < list.length; i++) {
            next[list[i].id] = { x: x, y: paddingTop }
            x += nodeW + gap
        }
        positions = next
    }
    function organizeGrid() {
        const list = root.actions || []
        const next = {}
        const cols = Math.max(1, Math.floor((flick.width - paddingLeft) / (nodeW + gap)))
        const cellH = nodeMinH + gap
        for (let i = 0; i < list.length; i++) {
            const col = i % cols
            const row = Math.floor(i / cols)
            next[list[i].id] = {
                x: paddingLeft + col * (nodeW + gap),
                y: paddingTop + row * cellH
            }
        }
        positions = next
    }

    // Place any newly-added steps below the existing layout. Existing
    // positions are left alone — this is the lazy "I added a step,
    // don't rearrange the others" path.
    function _placeNewSteps() {
        const list = root.actions || []
        if (list.length === 0) return
        const next = Object.assign({}, positions)
        let maxY = paddingTop
        for (let i = 0; i < list.length; i++) {
            const p = next[list[i].id]
            if (p) {
                const h = cardHeights[list[i].id] || nodeMinH
                maxY = Math.max(maxY, p.y + h + gap)
            }
        }
        let dirty = false
        for (let i = 0; i < list.length; i++) {
            if (!next[list[i].id]) {
                next[list[i].id] = {
                    x: Math.max(paddingLeft, (flick.width - nodeW) / 2),
                    y: maxY
                }
                maxY += nodeMinH + gap
                dirty = true
            }
        }
        if (dirty) positions = next
    }
    onActionsChanged: _placeNewSteps()
    Component.onCompleted: _placeNewSteps()

    // ============ Drag preview (palette → canvas) ============
    // The palette calls these methods directly; we render a card-
    // shaped semi-transparent ghost following the cursor in canvas-
    // local coordinates. Decoupling from the Drag/DropArea framework
    // lets us draw a real preview instead of a system drag cursor.

    property string ghostKind: ""
    property real ghostX: 0
    property real ghostY: 0
    readonly property bool ghostActive: ghostKind.length > 0

    function previewDrag(kind, sceneX, sceneY) {
        const local = root.mapFromItem(null, sceneX, sceneY)
        ghostKind = kind
        ghostX = local.x
        ghostY = local.y
    }
    function moveDragPreview(sceneX, sceneY) {
        const local = root.mapFromItem(null, sceneX, sceneY)
        ghostX = local.x
        ghostY = local.y
    }
    function endDragPreview(sceneX, sceneY, dropped) {
        const local = root.mapFromItem(null, sceneX, sceneY)
        const inBounds = local.x >= 0 && local.x <= root.width
                       && local.y >= 0 && local.y <= root.height
        if (dropped && inBounds && ghostKind.length > 0) {
            // Convert to Flickable contentItem coords (account for scroll).
            const fLocal = flick.mapFromItem(root, local.x, local.y)
            const cx = fLocal.x + flick.contentX - nodeW / 2
            const cy = fLocal.y + flick.contentY - nodeMinH / 2
            root.addStepAtRequested(ghostKind, Math.max(0, cx), Math.max(0, cy))
        }
        ghostKind = ""
    }

    // ============ Content extent ============

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
            const h = cardHeights[list[i].id] || nodeMinH
            if (p) my = Math.max(my, p.y + h + paddingBottom)
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

        MouseArea {
            anchors.fill: parent
            z: 0
            onClicked: root.deselectRequested()
        }

        // ============ Wires (linear sequence) ============

        Item {
            id: wireLayer
            anchors.fill: parent
            z: 1

            Repeater {
                model: Math.max(0, (root.actions || []).length - 1)
                delegate: Shape {
                    readonly property string fromId: root.actions[index] ? root.actions[index].id : ""
                    readonly property string toId: root.actions[index + 1] ? root.actions[index + 1].id : ""
                    readonly property var fromPos: root.positions[fromId]
                    readonly property var toPos: root.positions[toId]
                    readonly property real fromH: root.cardHeights[fromId] || root.nodeMinH
                    readonly property real toH: root.cardHeights[toId] || root.nodeMinH
                    readonly property var route: _routeWire(fromPos, toPos, fromH, toH)

                    visible: fromPos !== undefined && toPos !== undefined
                    anchors.fill: parent
                    smooth: true
                    layer.enabled: true
                    layer.samples: 4

                    // Direction is signalled by flowing dashes that
                    // march from source to target — the same trick
                    // n8n / Blender's node editor use. No arrowheads
                    // means two wires meeting at the same point on a
                    // card stay readable; the marching dashes still
                    // tell you which way each one runs.
                    //
                    // Pattern total = 4 + 8 = 12; animating dashOffset
                    // from 0 to -12 over 1200ms produces one full
                    // cycle per ~1.2s. Negative offset because Qt's
                    // dash convention shifts the pattern away from
                    // the path origin — negative makes the visual
                    // flow agree with the path's direction.
                    ShapePath {
                        strokeColor: Qt.rgba(0.55, 0.78, 0.88, 0.75)
                        strokeWidth: 1.6
                        fillColor: "transparent"
                        strokeStyle: Theme.reduceMotion ? ShapePath.SolidLine : ShapePath.DashLine
                        dashPattern: [4, 8]

                        startX: route.sx
                        startY: route.sy
                        PathCubic {
                            x: route.tx; y: route.ty
                            control1X: route.axis === "h" ? (route.sx + (route.tx - route.sx) / 2) : route.sx
                            control1Y: route.axis === "h" ? route.sy : (route.sy + (route.ty - route.sy) / 2)
                            control2X: route.axis === "h" ? (route.sx + (route.tx - route.sx) / 2) : route.tx
                            control2Y: route.axis === "h" ? route.ty : (route.sy + (route.ty - route.sy) / 2)
                        }

                        NumberAnimation on dashOffset {
                            from: 0
                            to: -12
                            duration: 1200
                            loops: Animation.Infinite
                            running: !Theme.reduceMotion
                        }
                    }
                }
            }
        }

        // ============ Cards ============

        Repeater {
            id: nodeRep
            model: root.actions

            delegate: Item {
                id: cardItem
                width: root.nodeW
                height: card.height
                z: dragArea.drag.active ? 100 : 2

                // Pin the outer Repeater's index to a stable property
                // so inner Repeaters (rewire menu) don't shadow it
                // with their own model.index.
                readonly property int stepIdx: model.index
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

                function _syncFromPositions() {
                    // Don't fight the drag: while the user is moving
                    // this card, x/y are owned by Qt's drag system.
                    // The drag handler writes positions on every step
                    // so wires track live; if we re-applied positions
                    // back to x/y here we'd just round-trip identical
                    // values and add jitter.
                    if (dragArea.drag.active) return
                    const p = root.positions[stepId]
                    if (p) { x = p.x; y = p.y }
                }
                Component.onCompleted: { _syncFromPositions(); _publishHeight() }
                Connections {
                    target: root
                    function onPositionsChanged() { cardItem._syncFromPositions() }
                }

                function _publishHeight() {
                    if (!stepId) return
                    if (root.cardHeights[stepId] === card.height) return
                    const next = Object.assign({}, root.cardHeights)
                    next[stepId] = card.height
                    root.cardHeights = next
                }
                Connections {
                    target: card
                    function onHeightChanged() { cardItem._publishHeight() }
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
                        drag.target: cardItem
                        drag.axis: Drag.XAndYAxis
                        drag.threshold: 4
                        property bool _wasDragged: false
                        onPressed: _wasDragged = false
                        // Write positions on every drag step (not just
                        // on release) so wires track the card live.
                        // The map is small enough that an Object.assign
                        // per mouse move is negligible at typical
                        // workflow sizes.
                        onPositionChanged: {
                            if (drag.active) {
                                _wasDragged = true
                                const next = Object.assign({}, root.positions)
                                next[cardItem.stepId] = { x: cardItem.x, y: cardItem.y }
                                root.positions = next
                            }
                        }
                        onReleased: {
                            if (_wasDragged) {
                                // Final commit — same shape; the live
                                // updates above should have already
                                // landed on the last frame, but write
                                // it once more so the saved state is
                                // unambiguous.
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

                    // ============ Rewire button ============
                    // Hover-revealed pill in the card's top-left corner.
                    // Click opens a menu with PRECEDED BY / FOLLOWED BY
                    // sections — choose any other step to drop into
                    // either role. Replaces the four port-dot drag
                    // mechanic, which was finicky and let users wire
                    // arrows in directions that didn't actually map
                    // to a sequential reorder.
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.leftMargin: 8
                        anchors.topMargin: 8
                        width: 22; height: 22; radius: 11
                        color: rewireArea.containsMouse
                            ? Theme.accent
                            : Theme.surface3
                        border.color: rewireArea.containsMouse ? Theme.accent : Theme.lineSoft
                        border.width: 1
                        opacity: dragArea.containsMouse || cardItem.isSelected ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: Theme.durFast } }
                        Behavior on color { ColorAnimation { duration: Theme.durFast } }

                        Text {
                            anchors.centerIn: parent
                            text: "⇄"
                            color: rewireArea.containsMouse ? Theme.accentText : Theme.text2
                            font.family: Theme.familyBody
                            font.pixelSize: 12
                            font.weight: Font.Bold
                        }

                        MouseArea {
                            id: rewireArea
                            anchors.fill: parent
                            anchors.margins: -4
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: rewireMenu.popup()
                            ToolTip.visible: containsMouse
                            ToolTip.delay: 400
                            ToolTip.text: "Set predecessor / successor"
                        }
                    }

                    WfMenu {
                        id: rewireMenu

                        // Section header — disabled WfMenuItem used as
                        // a non-clickable label.
                        WfMenuItem {
                            text: "↑  PRECEDED BY"
                            enabled: false
                        }
                        Repeater {
                            model: root.actions
                            delegate: WfMenuItem {
                                // Skip the card itself and its current
                                // predecessor (no-op), and the card
                                // immediately after it (current self
                                // in the predecessor role wouldn't
                                // change anything).
                                readonly property bool _show:
                                    model.index !== cardItem.stepIdx
                                    && model.index !== cardItem.stepIdx - 1
                                visible: _show
                                height: _show ? implicitHeight : 0
                                text: "  " + String(model.index + 1).padStart(2, "0")
                                      + "  ·  " + (modelData ? (modelData.summary || "") : "")
                                onTriggered: root.predecessorChosen(cardItem.stepIdx, model.index)
                            }
                        }

                        MenuSeparator {}

                        WfMenuItem {
                            text: "↓  FOLLOWED BY"
                            enabled: false
                        }
                        Repeater {
                            model: root.actions
                            delegate: WfMenuItem {
                                readonly property bool _show:
                                    model.index !== cardItem.stepIdx
                                    && model.index !== cardItem.stepIdx + 1
                                visible: _show
                                height: _show ? implicitHeight : 0
                                text: "  " + String(model.index + 1).padStart(2, "0")
                                      + "  ·  " + (modelData ? (modelData.summary || "") : "")
                                onTriggered: root.successorChosen(cardItem.stepIdx, model.index)
                            }
                        }
                    }
                }
            }
        }
    }

    // ============ Drag preview ghost (palette → canvas) ============
    Rectangle {
        visible: root.ghostActive
        x: root.ghostX - root.nodeW / 2
        y: root.ghostY - root.nodeMinH / 2
        width: root.nodeW
        height: root.nodeMinH
        z: 200
        opacity: 0.7
        radius: 14
        color: Theme.surface
        border.color: Theme.accent
        border.width: 2

        Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8

            Row {
                width: parent.width
                Text {
                    text: root.ghostKind.toUpperCase()
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: 10
                    font.weight: Font.Bold
                    font.letterSpacing: 1.4
                }
            }
            GradientPill {
                kind: root.ghostKind
                text: "(new step)"
                icon: Theme.catGlyph(root.ghostKind)
                width: parent.width
            }
        }
    }

    // ============ Floating UI ============

    // One-shot organize buttons. Click rearranges every card; no
    // sticky mode, no automatic re-layout on resize / inspector
    // slide / step add.
    Rectangle {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 8
        anchors.rightMargin: 8
        z: 60
        width: orgRow.implicitWidth + 12
        height: 34
        radius: 8
        color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.94)
        border.color: Theme.lineSoft
        border.width: 1

        Row {
            id: orgRow
            anchors.centerIn: parent
            spacing: 4

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Tidy:"
                color: Theme.text3
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontXs
                rightPadding: 4
            }

            Repeater {
                model: [
                    { glyph: "≡",  tip: "Tidy as a vertical stack",     action: organizeVertical   },
                    { glyph: "⫼",  tip: "Tidy as a horizontal row",     action: organizeHorizontal },
                    { glyph: "▦",  tip: "Tidy as a wrapping grid",      action: organizeGrid       }
                ]
                delegate: Rectangle {
                    width: 28; height: 26; radius: 6
                    anchors.verticalCenter: parent.verticalCenter
                    color: orgArea.containsMouse ? Theme.surface2 : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    Text {
                        anchors.centerIn: parent
                        text: modelData.glyph
                        color: Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: 14
                    }
                    MouseArea {
                        id: orgArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: modelData.action()
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: modelData.tip
                    }
                }
            }
        }
    }

    // ============ Helpers ============

    // Smart wire routing: pick the source's exit side and the target's
    // entry side based on the geometry between the two cards. Wire
    // exits whichever side faces the target, so a horizontal layout
    // gets right→left wires and a vertical layout gets bottom→top
    // wires without anyone setting a mode.
    function _routeWire(fromPos, toPos, fromH, toH) {
        if (!fromPos || !toPos) return { sx: 0, sy: 0, tx: 0, ty: 0, axis: "v" }
        const fromCx = fromPos.x + nodeW / 2
        const fromCy = fromPos.y + fromH / 2
        const toCx = toPos.x + nodeW / 2
        const toCy = toPos.y + toH / 2
        const dx = toCx - fromCx
        const dy = toCy - fromCy
        // Bias slightly toward vertical so cards stacked roughly on
        // top of each other don't flip to horizontal routing on a
        // small x-jitter.
        if (Math.abs(dx) > Math.abs(dy) * 1.3) {
            if (dx > 0) {
                return { sx: fromPos.x + nodeW, sy: fromCy, tx: toPos.x,            ty: toCy, axis: "h" }
            } else {
                return { sx: fromPos.x,         sy: fromCy, tx: toPos.x + nodeW,    ty: toCy, axis: "h" }
            }
        } else {
            if (dy > 0) {
                return { sx: fromCx, sy: fromPos.y + fromH, tx: toCx, ty: toPos.y,         axis: "v" }
            } else {
                return { sx: fromCx, sy: fromPos.y,         tx: toCx, ty: toPos.y + toH,   axis: "v" }
            }
        }
    }

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
