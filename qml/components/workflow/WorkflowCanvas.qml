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

    // "curve" (default Bezier) | "ortho" (straight segments, hard
    // 90° corners). Doesn't affect the marching-dash animation —
    // dashes still flow along whichever path shape is active.
    property string wireStyle: "curve"

    // ============ Zoom ============
    // Plain wheel zooms around the cursor; Tidy actions auto-fit.
    // Drag empty canvas to pan (Flickable). All card positions stay
    // in logical (unscaled) world coords — only the world container
    // carries the scale.
    property real zoom: 1.0
    readonly property real minZoom: 0.4
    readonly property real maxZoom: 1.6

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
    // canvasOrigin centres the spawn area inside the 12k canvas
    // span, so the user can pan in every direction from the cards
    // (otherwise pan-left dead-ends at contentX = 0). paddingLeft /
    // paddingTop are the "tucked into the upper-left of the card
    // area" offsets relative to that centre.
    readonly property int canvasOrigin: canvasSpan / 2
    readonly property int paddingLeft: canvasOrigin - 200
    readonly property int paddingTop: canvasOrigin - 120
    readonly property int paddingBottom: 60

    // ============ Layout actions (one-shot) ============

    function organizeVertical() {
        const list = root.actions || []
        const next = {}
        const x = paddingLeft
        let y = paddingTop
        for (let i = 0; i < list.length; i++) {
            next[list[i].id] = { x: x, y: y }
            y += (cardHeights[list[i].id] || nodeMinH) + gap
        }
        positions = next
        Qt.callLater(_zoomToFit)
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
        Qt.callLater(_zoomToFit)
    }
    function organizeGrid() {
        const list = root.actions || []
        const next = {}
        // Pick a column count that produces roughly square footprint
        // of the resulting grid — looks better than wrapping to fit
        // the current viewport, which biases wide screens into long
        // single rows.
        const cols = Math.max(1, Math.ceil(Math.sqrt(list.length)))
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
        Qt.callLater(_zoomToFit)
    }

    // Set zoom and contentX/Y so every card sits inside the viewport
    // with comfortable padding. Hits the zoom caps when the layout
    // is bigger / smaller than fits cleanly. Animated for the same
    // reason as +/-: it's a deliberate user action, not a continuous
    // input where animation would feel laggy.
    function _zoomToFit() {
        const list = root.actions || []
        if (list.length === 0) return
        let minX = Infinity, minY = Infinity
        let maxX = -Infinity, maxY = -Infinity
        let any = false
        for (let i = 0; i < list.length; i++) {
            const p = positions[list[i].id]
            if (!p) continue
            const h = cardHeights[list[i].id] || nodeMinH
            minX = Math.min(minX, p.x)
            minY = Math.min(minY, p.y)
            maxX = Math.max(maxX, p.x + nodeW)
            maxY = Math.max(maxY, p.y + h)
            any = true
        }
        if (!any) return
        const padding = 60
        const fitW = (maxX - minX) + padding * 2
        const fitH = (maxY - minY) + padding * 2
        if (fitW <= 0 || fitH <= 0 || flick.width <= 0 || flick.height <= 0) return
        let z = Math.min(flick.width / fitW, flick.height / fitH)
        z = Math.max(minZoom, Math.min(maxZoom, z))
        const cx = ((minX + maxX) / 2) * z
        const cy = ((minY + maxY) / 2) * z
        _animateZoomTo(z,
                       Math.max(0, cx - flick.width / 2),
                       Math.max(0, cy - flick.height / 2))
    }

    // Zoom around a viewport-local anchor so the world coord under
    // the cursor stays under the cursor through the change. Both
    // wheel and button paths funnel here — Behaviors on zoom +
    // contentX/Y do the smoothing, so wheel ticks compose naturally
    // (each new tick interrupts the in-flight animation toward a
    // new target rather than queueing).
    function _zoomAt(viewportPoint, requested) {
        const z = Math.max(minZoom, Math.min(maxZoom, requested))
        if (z === zoom) return
        const wx = (viewportPoint.x + flick.contentX) / zoom
        const wy = (viewportPoint.y + flick.contentY) / zoom
        const newCW = root.contentW * z
        const newCH = root.contentH * z
        zoom = z
        flick.contentX = Math.max(0, Math.min(Math.max(0, newCW - flick.width),
                                              wx * z - viewportPoint.x))
        flick.contentY = Math.max(0, Math.min(Math.max(0, newCH - flick.height),
                                              wy * z - viewportPoint.y))
    }

    // Step zoom from the viewport center. Snaps to the nearest 10%
    // step so repeated +/- clicks land at clean 60% / 70% / … values
    // regardless of where wheel zoom left things.
    function _zoomBy(delta) {
        const cur = Math.round(zoom * 10) / 10
        _zoomAt(Qt.point(flick.width / 2, flick.height / 2), cur + delta)
    }

    // Set zoom + pan in one shot. Behaviors handle the animation.
    function _animateZoomTo(newZoom, newCX, newCY) {
        zoom = newZoom
        flick.contentX = newCX
        flick.contentY = newCY
    }

    // Smooth animation on zoom — both wheel and button paths route
    // changes through here, so all zoom transitions feel the same.
    Behavior on zoom {
        enabled: !Theme.reduceMotion
        NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Theme.easingStd }
    }

    // Place any newly-added steps below the existing layout. Existing
    // positions are left alone — this is the lazy "I added a step,
    // don't rearrange the others" path. When this is the first time
    // any positions are being assigned (initial workflow load), we
    // auto-fit the viewport so the user lands on the cards rather
    // than at scene origin (which is far from where cards spawn now
    // that paddingLeft is offset to the canvas centre).
    function _placeNewSteps() {
        const list = root.actions || []
        if (list.length === 0) return
        const wasEmpty = Object.keys(positions).length === 0
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
                next[list[i].id] = { x: paddingLeft, y: maxY }
                maxY += nodeMinH + gap
                dirty = true
            }
        }
        if (dirty) {
            positions = next
            if (wasEmpty) Qt.callLater(_zoomToFit)
        }
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
            // Map scene coords directly through the scaled world so
            // the drop point lands in logical coords regardless of
            // current zoom level.
            const w = world.mapFromItem(null, sceneX, sceneY)
            const cx = w.x - nodeW / 2
            const cy = w.y - nodeMinH / 2
            root.addStepAtRequested(ghostKind, Math.max(0, cx), Math.max(0, cy))
        }
        ghostKind = ""
    }

    // ============ Content extent ============
    // Effectively-infinite canvas. A fixed-but-large unscaled span
    // keeps the Flickable from clamping the pan to the card-bounding
    // box — the user can drag empty space anywhere they like, and
    // dropping cards far from origin doesn't run into a wall. Span
    // is unscaled; Flickable.contentWidth multiplies by zoom.
    readonly property int canvasSpan: 12000

    readonly property int contentW: {
        let mx = canvasSpan
        const list = root.actions || []
        for (let i = 0; i < list.length; i++) {
            const p = positions[list[i].id]
            if (p) mx = Math.max(mx, p.x + nodeW + paddingLeft)
        }
        return mx
    }
    readonly property int contentH: {
        let my = canvasSpan
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
        contentWidth: root.contentW * root.zoom
        contentHeight: root.contentH * root.zoom
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // Explicit DragHandler below owns canvas pan. Flickable's
        // built-in drag fights TapHandler / card MouseAreas in ways
        // that left the canvas stuck — turning interactive off lets
        // wheel + scrollbars still scroll the contentItem while pan
        // is unambiguously handled by the DragHandler.
        interactive: false

        // Animate contentX / contentY together with the zoom Behavior
        // so the cursor anchor stays correct mid-zoom (zoom and
        // contentX have to interpolate at the same fraction of
        // progress, otherwise the world coord under the cursor
        // drifts during the animation). Disabled while panning, so
        // drag-pan stays instant.
        Behavior on contentX {
            enabled: !Theme.reduceMotion && !panHandler.active
            NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Theme.easingStd }
        }
        Behavior on contentY {
            enabled: !Theme.reduceMotion && !panHandler.active
            NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Theme.easingStd }
        }

        // Plain wheel zooms with the cursor as anchor.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            z: 5
            onWheel: (wheel) => {
                wheel.accepted = true
                const step = (wheel.angleDelta.y / 120) * 0.1
                // wheel.x / wheel.y are in this MouseArea's local
                // coords. anchors.fill: parent makes the parent the
                // Flickable's contentItem, so they're scaled-content-
                // item coords already. _zoomAt expects viewport-local
                // (the buttons pass flick.width/2 which is viewport
                // sized), so subtract the scroll offset back out.
                const vx = wheel.x - flick.contentX
                const vy = wheel.y - flick.contentY
                root._zoomAt(Qt.point(vx, vy), root.zoom + step)
            }
        }

        // Click-and-drag on empty canvas pans the viewport. Cards'
        // own MouseAreas grab their press exclusively before this
        // handler can claim it, so dragging a card moves the card
        // (not the canvas), and pressing on a card and releasing
        // without motion still fires its click. Everywhere else
        // — the empty grid background between cards — this
        // handler takes the gesture and pans.
        DragHandler {
            id: panHandler
            target: null
            property real _startX: 0
            property real _startY: 0
            onActiveChanged: {
                if (active) {
                    _startX = flick.contentX
                    _startY = flick.contentY
                }
            }
            onTranslationChanged: {
                if (!active) return
                const maxX = Math.max(0, flick.contentWidth - flick.width)
                const maxY = Math.max(0, flick.contentHeight - flick.height)
                flick.contentX = Math.max(0, Math.min(maxX, _startX - translation.x))
                flick.contentY = Math.max(0, Math.min(maxY, _startY - translation.y))
            }
        }

        // Open hand when hovering empty canvas, closed hand while
        // panning. Cards have their own MouseAreas that override the
        // cursor when hovered (pointer, then closed hand on drag),
        // so this only paints the empty grid area.
        HoverHandler {
            cursorShape: panHandler.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        }

        // Deselect on tap of empty area. TapHandler doesn't fire if
        // the gesture became a drag (DragHandler claims it past the
        // motion threshold), so this is harmless alongside pan.
        TapHandler {
            onTapped: root.deselectRequested()
        }

        // World container. Holds wires + cards in unscaled (logical)
        // coords; the scale property applies the zoom to everything
        // inside in one shot, so positions / drag math / smart wire
        // routing all stay in logical space.
        Item {
            id: world
            width: root.contentW
            height: root.contentH
            transformOrigin: Item.TopLeft
            scale: root.zoom

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
                    // No layer.enabled here — the marching-dash
                    // animation re-rasterises the stroke every
                    // frame anyway, so caching it to an offscreen
                    // layer doubles the work for no gain. With
                    // ten wires that compounds into noticeable
                    // lag during zoom / drag.

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

                        // Path data is built from JS so the same
                        // ShapePath can switch between Bezier and
                        // orthogonal routing without rebuilding the
                        // Shape. dashOffset still animates the
                        // resulting stroke either way.
                        startX: route.sx
                        startY: route.sy
                        PathSvg {
                            path: root.wireStyle === "ortho"
                                ? _orthoPath(route)
                                : _curvePath(route)
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

                // Suppress the position Behaviors during the very
                // first sync after creation. Without this, every
                // Repeater rebuild (which happens on each workflow
                // mutation) creates fresh delegates at x=0, y=0 and
                // the Behavior animates them out to their saved
                // positions over durSlow — visible as the cards
                // collapsing toward origin and re-fanning out on
                // every drop / save.
                property bool _settled: false

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
                Component.onCompleted: { _syncFromPositions(); _publishHeight(); _settled = true }
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
                    enabled: cardItem._settled && !dragArea.drag.active
                    NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Theme.easingStd }
                }
                Behavior on y {
                    enabled: cardItem._settled && !dragArea.drag.active
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

                    // No drop shadow on canvas cards — see CLAUDE.md
                    // design principle ("Flat, not skeuomorphic. No
                    // drop shadows except for a true overlay"). Per-
                    // card MultiEffect blur was also the dominant
                    // perf cost during zoom; ten cards meant ten full
                    // blur passes re-rasterised on every scale tick.

                    MouseArea {
                        id: dragArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: dragArea.drag.active ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                        // Don't let the canvas pan DragHandler steal
                        // a card drag once motion crosses its
                        // threshold — the user would end up panning
                        // mid-card-drag.
                        preventStealing: true
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

                            // Rewire button. Lives inside the header
                            // row so it always reserves layout space
                            // — opacity controls visibility (hover or
                            // selected), so the kind label never has
                            // to sit behind the pill.
                            Rectangle {
                                id: rewireBtn
                                width: 22; height: 22; radius: 11
                                anchors.verticalCenter: parent.verticalCenter
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

                            Text {
                                text: cardItem.kind.toUpperCase()
                                color: Theme.text3
                                font.family: Theme.familyBody
                                font.pixelSize: 10
                                font.weight: Font.Bold
                                font.letterSpacing: 1.4
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - rewireBtn.width - numBadge.width - statusDot.width - parent.spacing * 3
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

                    // Rewire menu — popup()'d from the ⇄ button now
                    // living in the header row above. Kept here as a
                    // child of the card so step.id captures stay
                    // bound to this delegate's stepIdx.
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
        }   // end of world Item
    }       // end of Flickable

    // ============ Drag preview ghost (palette → canvas) ============
    // Scale matches the canvas zoom so the ghost's visual size lines
    // up with how the dropped card will render — without it, dropping
    // at 50% zoom would show a full-size ghost that snaps to a
    // half-size card on landing. transformOrigin: Center keeps the
    // ghost centred on the cursor through any zoom level.
    Rectangle {
        visible: root.ghostActive
        transformOrigin: Item.Center
        scale: root.zoom
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

    // Three stacked pills — Tidy / Wires / Zoom each on their own
    // row so labels read cleanly and no row gets so wide it crowds
    // the canvas. Each pill is a Rectangle wrapping a Row of icon
    // buttons; spacing is tight (4px) and a leading label sets
    // context for the row.
    Column {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 8
        anchors.rightMargin: 8
        spacing: 6
        z: 60

        // ---- Tidy
        Rectangle {
            anchors.right: parent.right
            width: tidyRow.implicitWidth + 12
            height: 34
            radius: 8
            color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.94)
            border.color: Theme.lineSoft
            border.width: 1

            Row {
                id: tidyRow
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
                        { glyph: "≡",  tip: "Tidy as a vertical stack",  action: organizeVertical   },
                        { glyph: "⫼",  tip: "Tidy as a horizontal row",  action: organizeHorizontal },
                        { glyph: "▦",  tip: "Tidy as a wrapping grid",   action: organizeGrid       }
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

        // ---- Wires
        Rectangle {
            anchors.right: parent.right
            width: wiresRow.implicitWidth + 12
            height: 34
            radius: 8
            color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.94)
            border.color: Theme.lineSoft
            border.width: 1

            Row {
                id: wiresRow
                anchors.centerIn: parent
                spacing: 4

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Wires:"
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    rightPadding: 4
                }

                Repeater {
                    model: [
                        { id: "curve", glyph: "⌒", tip: "Curved (Bezier) wires" },
                        { id: "ortho", glyph: "⌐", tip: "Stepped (90°) wires"   }
                    ]
                    delegate: Rectangle {
                        readonly property bool isOn: root.wireStyle === modelData.id
                        width: 28; height: 26; radius: 6
                        anchors.verticalCenter: parent.verticalCenter
                        color: isOn
                            ? Theme.accentWash(0.16)
                            : (wsArea.containsMouse ? Theme.surface2 : "transparent")
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
                            id: wsArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.wireStyle = modelData.id
                            ToolTip.visible: containsMouse
                            ToolTip.delay: 400
                            ToolTip.text: modelData.tip
                        }
                    }
                }
            }
        }

        // ---- Zoom: − [percentage] + [Fit]
        Rectangle {
            anchors.right: parent.right
            width: zoomRow.implicitWidth + 12
            height: 34
            radius: 8
            color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.94)
            border.color: Theme.lineSoft
            border.width: 1

            Row {
                id: zoomRow
                anchors.centerIn: parent
                spacing: 4

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Zoom:"
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    rightPadding: 4
                }

                Rectangle {
                    width: 24; height: 26; radius: 6
                    anchors.verticalCenter: parent.verticalCenter
                    color: zOutArea.containsMouse ? Theme.surface2 : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    Text {
                        anchors.centerIn: parent
                        text: "−"
                        color: Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: 16
                        font.weight: Font.Medium
                    }
                    MouseArea {
                        id: zOutArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._zoomBy(-0.1)
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "Zoom out"
                    }
                }

                Rectangle {
                    width: 44; height: 26; radius: 6
                    anchors.verticalCenter: parent.verticalCenter
                    color: zPctArea.containsMouse ? Theme.surface2 : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    Text {
                        anchors.centerIn: parent
                        text: Math.round(root.zoom * 100) + "%"
                        color: Theme.text2
                        font.family: Theme.familyMono
                        font.pixelSize: 11
                    }
                    MouseArea {
                        id: zPctArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._animateZoomTo(1.0, flick.contentX, flick.contentY)
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "Reset zoom to 100%"
                    }
                }

                Rectangle {
                    width: 24; height: 26; radius: 6
                    anchors.verticalCenter: parent.verticalCenter
                    color: zInArea.containsMouse ? Theme.surface2 : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    Text {
                        anchors.centerIn: parent
                        text: "+"
                        color: Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: 14
                        font.weight: Font.Medium
                    }
                    MouseArea {
                        id: zInArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._zoomBy(0.1)
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "Zoom in"
                    }
                }

                Rectangle {
                    width: 28; height: 26; radius: 6
                    anchors.verticalCenter: parent.verticalCenter
                    color: zFitArea.containsMouse ? Theme.surface2 : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    Text {
                        anchors.centerIn: parent
                        text: "⊡"
                        color: Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: 14
                    }
                    MouseArea {
                        id: zFitArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._zoomToFit()
                        ToolTip.visible: containsMouse
                        ToolTip.delay: 400
                        ToolTip.text: "Fit all cards"
                    }
                }
            }
        }
    }

    // ============ Helpers ============

    // SVG path data for a Bezier-style wire. Control points are
    // pulled along the routing axis so the curve eases out of the
    // source and into the target.
    function _curvePath(route) {
        if (!route) return ""
        const c1x = route.axis === "h" ? (route.sx + (route.tx - route.sx) / 2) : route.sx
        const c1y = route.axis === "h" ? route.sy : (route.sy + (route.ty - route.sy) / 2)
        const c2x = route.axis === "h" ? (route.sx + (route.tx - route.sx) / 2) : route.tx
        const c2y = route.axis === "h" ? route.ty : (route.sy + (route.ty - route.sy) / 2)
        return "M " + route.sx + " " + route.sy
             + " C " + c1x + " " + c1y
             + " "   + c2x + " " + c2y
             + " "   + route.tx + " " + route.ty
    }

    // SVG path data for an orthogonal wire — three straight segments
    // joined at hard 90° corners. The midpoint sits halfway along the
    // routing axis so the elbow lands centred between the two cards.
    function _orthoPath(route) {
        if (!route) return ""
        if (route.axis === "h") {
            const midX = (route.sx + route.tx) / 2
            return "M " + route.sx + " " + route.sy
                 + " L " + midX     + " " + route.sy
                 + " L " + midX     + " " + route.ty
                 + " L " + route.tx + " " + route.ty
        } else {
            const midY = (route.sy + route.ty) / 2
            return "M " + route.sx + " " + route.sy
                 + " L " + route.sx + " " + midY
                 + " L " + route.tx + " " + midY
                 + " L " + route.tx + " " + route.ty
        }
    }

    // Pick exit / entry sides per pair so wires avoid the obvious
    // collisions:
    //   - Same row (cards' Y ranges overlap, X ranges don't): horizontal
    //     axis. Wire travels through the column-gap.
    //   - Same column (X ranges overlap, Y ranges don't): vertical
    //     axis. Wire travels through the row-gap.
    //   - Diagonal (neither overlap): vertical axis. The horizontal
    //     leg of the path lives in the row-gap, which is usually
    //     empty even in dense grids; the horizontal alternative
    //     would put the leg in the source's row, where it crosses
    //     other cards.
    //   - Both ranges overlap (cards stacked / nested): fall back
    //     to the magnitude heuristic.
    function _routeWire(fromPos, toPos, fromH, toH) {
        if (!fromPos || !toPos) return { sx: 0, sy: 0, tx: 0, ty: 0, axis: "v" }
        const fromCx = fromPos.x + nodeW / 2
        const fromCy = fromPos.y + fromH / 2
        const toCx = toPos.x + nodeW / 2
        const toCy = toPos.y + toH / 2

        const xOverlap = !(fromPos.x + nodeW <= toPos.x || toPos.x + nodeW <= fromPos.x)
        const yOverlap = !(fromPos.y + fromH <= toPos.y || toPos.y + toH <= fromPos.y)

        let useVertical
        if (yOverlap && !xOverlap) {
            useVertical = false
        } else if (xOverlap && !yOverlap) {
            useVertical = true
        } else if (!xOverlap && !yOverlap) {
            // Diagonal — prefer vertical so horizontal leg stays in
            // the row-gap rather than crossing cards in the source row.
            useVertical = true
        } else {
            const dx = toCx - fromCx
            const dy = toCy - fromCy
            useVertical = Math.abs(dy) >= Math.abs(dx)
        }

        if (!useVertical) {
            if (toCx > fromCx) {
                return { sx: fromPos.x + nodeW, sy: fromCy, tx: toPos.x,         ty: toCy, axis: "h" }
            } else {
                return { sx: fromPos.x,         sy: fromCy, tx: toPos.x + nodeW, ty: toCy, axis: "h" }
            }
        } else {
            if (toCy > fromCy) {
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
