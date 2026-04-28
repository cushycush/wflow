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
    property int selectedInnerIndex: -1
    property var stepStatuses: ({})

    // Reactive position / size stores. Each card writes into these
    // on drag-release and on size-change; wires + hit-tests read
    // from them. Width is per-card so containers (which are wider
    // than action cards) get correct wire endpoints + drop bounds.
    property var positions: ({})    // { [id]: {x, y} }
    property var cardHeights: ({})  // { [id]: number }
    property var cardWidths: ({})   // { [id]: number }

    // Width a given step should render at — derived from the shaped
    // action's rawKind. Containers are wider so the inner-step drop
    // zone has a meaningful visual footprint; notes are narrower
    // since they're annotations, not first-class operations.
    function _widthForKind(rawKind) {
        if (rawKind === "conditional" || rawKind === "repeat") return containerW
        if (rawKind === "note") return noteW
        return nodeW
    }

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
    signal deleteStepRequested(int index)
    // Inner-step mutations on flow-control containers (when / unless
    // / repeat). Routed by WorkflowPage to the same handlers the
    // inspector uses.
    signal addInnerStepRequested(int stepIndex, string kind)
    signal deleteInnerStepRequested(int stepIndex, int innerIndex)
    // Move an existing top-level step into a container's inner
    // sequence. Page does the splice + push and refreshes selection.
    signal moveStepToContainerRequested(int fromIndex, int containerIndex)
    // Click an inner mini-row → select that inner step in the
    // inspector. Pairs with editorContent.selectedInnerIndex on
    // WorkflowPage.
    signal selectInnerStep(int parentIndex, int innerIndex)
    // Click the container's "→" affordance → push that container's
    // index onto the crumb. WorkflowPage clears selection and the
    // canvas re-renders against the inner step list.
    signal openContainerRequested(int stepIndex)
    // Click "→ open import" on a `use NAME` card. WorkflowPage
    // resolves NAME through the workflow's imports map to an
    // absolute path, then signals up to Main.qml which adds a new
    // fragment tab. The canvas itself doesn't know about imports.
    signal openUseRequested(int stepIndex)
    // Rewire from a card's overflow menu — `stepIndex` is the card
    // that's being rewired, `otherIndex` is the chosen counterpart.
    // The page resolves these via _moveStep.
    signal predecessorChosen(int stepIndex, int otherIndex)
    signal successorChosen(int stepIndex, int otherIndex)

    readonly property int nodeW: 260
    readonly property int containerW: 360
    readonly property int noteW: 200
    readonly property int nodeMinH: 132
    readonly property int noteMinH: 56
    readonly property int gap: 36

    // Pairs of step indices that should be connected by a wire.
    // Notes are annotations (engine skips them), so wires bridge
    // over them — the previous operational step connects directly
    // to the next operational step. Computed once per actions
    // change; the wire Repeater uses this as its model.
    readonly property var _wirePairs: {
        const out = []
        const arr = root.actions || []
        let prev = -1
        for (let i = 0; i < arr.length; i++) {
            if (!arr[i]) continue
            if (arr[i].rawKind === "note") continue
            if (prev >= 0) out.push({ from: prev, to: i })
            prev = i
        }
        return out
    }
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
            x += _widthForKind(list[i].rawKind) + gap
        }
        positions = next
        Qt.callLater(_zoomToFit)
    }
    function organizeGrid() {
        const list = root.actions || []
        if (list.length === 0) return
        // Square-ish grid footprint (preferred over viewport-fit so
        // wide screens don't bias into a single long row).
        const cols = Math.max(1, Math.ceil(Math.sqrt(list.length)))

        // Container cards are 360px wide and routinely much taller
        // than nodeMinH once inner steps land — fixed cell math
        // (nodeW + gap, nodeMinH + gap) stacked them on top of each
        // other. Compute per-column widths and per-row heights from
        // the actual cards in each slot.
        const colWidths = []
        const rowHeights = []
        for (let i = 0; i < list.length; i++) {
            const a = list[i]
            const col = i % cols
            const row = Math.floor(i / cols)
            const w = cardWidths[a.id] || _widthForKind(a.rawKind)
            const h = cardHeights[a.id] || nodeMinH
            colWidths[col] = Math.max(colWidths[col] || 0, w)
            rowHeights[row] = Math.max(rowHeights[row] || 0, h)
        }

        // Cumulative origin per column / row.
        const colX = [paddingLeft]
        for (let c = 1; c < cols; c++) {
            colX.push(colX[c - 1] + colWidths[c - 1] + gap)
        }
        const rowY = [paddingTop]
        for (let r = 1; r < rowHeights.length; r++) {
            rowY.push(rowY[r - 1] + rowHeights[r - 1] + gap)
        }

        const next = {}
        for (let i = 0; i < list.length; i++) {
            const col = i % cols
            const row = Math.floor(i / cols)
            next[list[i].id] = { x: colX[col], y: rowY[row] }
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
            const w = cardWidths[list[i].id] || _widthForKind(list[i].rawKind)
            minX = Math.min(minX, p.x)
            minY = Math.min(minY, p.y)
            maxX = Math.max(maxX, p.x + w)
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
    // -1 when no container is under the drag cursor; otherwise the
    // top-level index of the container whose inner zone is being
    // hovered. Container cards bind a highlight to this so the drop
    // target is visually obvious during the drag.
    property int hoveredContainerIndex: -1

    // Walk the action list and return the index of any container
    // whose card bounds contain the given world point. Only checks
    // top-level containers — nested containers aren't drop targets
    // yet (single level of nesting on the canvas).
    function _containerAt(worldX, worldY) {
        const list = root.actions || []
        for (let i = 0; i < list.length; i++) {
            const a = list[i]
            if (!a) continue
            if (a.rawKind !== "conditional" && a.rawKind !== "repeat") continue
            const p = root.positions[a.id]
            if (!p) continue
            const w = root.cardWidths[a.id] || _widthForKind(a.rawKind)
            const h = root.cardHeights[a.id] || nodeMinH
            if (worldX >= p.x && worldX <= p.x + w
                && worldY >= p.y && worldY <= p.y + h) {
                return i
            }
        }
        return -1
    }

    function previewDrag(kind, sceneX, sceneY) {
        ghostKind = kind
        ghostX = sceneX
        ghostY = sceneY
        const w = world.mapFromItem(null, sceneX, sceneY)
        hoveredContainerIndex = _containerAt(w.x, w.y)
    }
    function moveDragPreview(sceneX, sceneY) {
        ghostX = sceneX
        ghostY = sceneY
        const w = world.mapFromItem(null, sceneX, sceneY)
        hoveredContainerIndex = _containerAt(w.x, w.y)
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
            const containerIdx = _containerAt(w.x, w.y)
            if (containerIdx >= 0) {
                // Drop on a container → add as inner step.
                root.addInnerStepRequested(containerIdx, ghostKind)
            } else {
                const cx = w.x - nodeW / 2
                const cy = w.y - nodeMinH / 2
                root.addStepAtRequested(ghostKind, Math.max(0, cx), Math.max(0, cy))
            }
        }
        ghostKind = ""
        hoveredContainerIndex = -1
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
            if (!p) continue
            const w = cardWidths[list[i].id] || _widthForKind(list[i].rawKind)
            mx = Math.max(mx, p.x + w + paddingLeft)
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

        // Wheel-only handler: no cursor, no hover claim, just zoom.
        // hoverEnabled: false + acceptedButtons: NoButton means this
        // area neither claims the cursor nor steals hover events —
        // cards underneath get their containsMouse signals as
        // expected so border-color hovers / rewire-button reveals
        // still work. Wheel events deliver because they're hit-
        // tested independently of hover.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            hoverEnabled: false
            z: 5
            onWheel: (wheel) => {
                wheel.accepted = true
                const step = (wheel.angleDelta.y / 120) * 0.1
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
                model: root._wirePairs
                delegate: Shape {
                    readonly property int fromIdx: modelData.from
                    readonly property int toIdx: modelData.to
                    readonly property string fromId: root.actions[fromIdx] ? root.actions[fromIdx].id : ""
                    readonly property string toId: root.actions[toIdx] ? root.actions[toIdx].id : ""
                    readonly property var fromPos: root.positions[fromId]
                    readonly property var toPos: root.positions[toId]
                    readonly property real fromH: root.cardHeights[fromId] || root.nodeMinH
                    readonly property real toH: root.cardHeights[toId] || root.nodeMinH
                    readonly property real fromW: root.cardWidths[fromId]
                        || _widthForKind(root.actions[fromIdx] ? root.actions[fromIdx].rawKind : "")
                    readonly property real toW: root.cardWidths[toId]
                        || _widthForKind(root.actions[toIdx] ? root.actions[toIdx].rawKind : "")
                    readonly property var route: _routeWire(fromPos, toPos, fromH, toH, fromW, toW)

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
                width: _widthForKind(rawKind)
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
                readonly property string rawKind: modelData ? (modelData.rawKind || "") : ""
                readonly property bool isContainer:
                    rawKind === "conditional" || rawKind === "repeat"
                // Notes are annotations, not workflow steps — the
                // engine skips them at runtime. Render lighter so
                // they read as canvas comments rather than first-
                // class operations; wires also skip them (see
                // _wirePairs at the canvas root).
                readonly property bool isNote: rawKind === "note"
                // True when a palette drag is hovering this card and
                // it's a container — drives the inner-zone highlight
                // so the user sees their drop will land inside.
                readonly property bool isHoverDropTarget:
                    root.hoveredContainerIndex === model.index && isContainer
                readonly property color cardBg:
                    isSelected ? Theme.surface2
                        : (isNote
                            ? Qt.rgba(Theme.surface3.r, Theme.surface3.g,
                                      Theme.surface3.b, 0.35)
                            : Theme.surface)
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
                Component.onCompleted: { _syncFromPositions(); _publishHeight(); _publishWidth(); _settled = true }
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
                function _publishWidth() {
                    if (!stepId) return
                    const w = cardItem.width
                    if (root.cardWidths[stepId] === w) return
                    const next = Object.assign({}, root.cardWidths)
                    next[stepId] = w
                    root.cardWidths = next
                }
                Connections {
                    target: card
                    function onHeightChanged() { cardItem._publishHeight() }
                }
                onWidthChanged: _publishWidth()

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
                    height: cardItem.isNote
                        ? Math.max(root.noteMinH, noteBody.implicitHeight + 18)
                        : Math.max(root.nodeMinH - 4, cardBody.implicitHeight + 24)
                    radius: cardItem.isNote ? 8 : 14
                    color: cardItem.cardBg
                    // Containers carry a tinted border (their pill
                    // colour) so when / unless / repeat read as
                    // structural blocks at a glance — ordinary action
                    // cards keep the neutral hairline. Notes get the
                    // softest border so they recede next to operations.
                    border.color: cardItem.isSelected
                        ? Qt.rgba(0.55, 0.78, 0.88, 0.9)
                        : (cardItem.isContainer
                            ? Theme.catFor(cardItem.kind)
                            : (cardItem.isNote
                                ? Theme.lineSoft
                                : (dragArea.containsMouse ? Theme.line : Theme.lineSoft)))
                    border.width: cardItem.isSelected ? 2 : (cardItem.isContainer ? 1.5 : 1)

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
                                // Highlight any container under the card's
                                // centre. Skip self so a container being
                                // dragged doesn't claim itself as a target.
                                const cx = cardItem.x + cardItem.width / 2
                                const cy = cardItem.y + cardItem.height / 2
                                const idx = _containerAt(cx, cy)
                                root.hoveredContainerIndex =
                                    (idx === model.index) ? -1 : idx
                            }
                        }
                        onReleased: {
                            if (_wasDragged) {
                                // Card centre over a different container
                                // → reparent: pull it out of the top-
                                // level sequence and append to that
                                // container's inner steps.
                                const cx = cardItem.x + cardItem.width / 2
                                const cy = cardItem.y + cardItem.height / 2
                                const targetIdx = _containerAt(cx, cy)
                                root.hoveredContainerIndex = -1
                                if (targetIdx >= 0 && targetIdx !== model.index) {
                                    root.moveStepToContainerRequested(
                                        model.index, targetIdx)
                                    return
                                }
                                // Otherwise commit the new position.
                                const next = Object.assign({}, root.positions)
                                next[cardItem.stepId] = { x: cardItem.x, y: cardItem.y }
                                root.positions = next
                            } else {
                                root.selectStep(model.index)
                            }
                        }
                    }

                    // Note-specific render — italic text with a soft
                    // "note" prefix label. Notes don't get the pill
                    // header, kind badge, status dot, or chip flow
                    // because they aren't workflow operations.
                    Column {
                        id: noteBody
                        visible: cardItem.isNote
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        anchors.topMargin: 10
                        spacing: 4

                        Row {
                            spacing: 8
                            width: parent.width

                            Text {
                                text: "¶ NOTE"
                                color: Theme.text3
                                font.family: Theme.familyBody
                                font.pixelSize: 9
                                font.weight: Font.Bold
                                font.letterSpacing: 1.2
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Item {
                                width: parent.width - 56 - noteDelBtn.width
                                height: 1
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Rectangle {
                                id: noteDelBtn
                                width: 18; height: 18; radius: 9
                                anchors.verticalCenter: parent.verticalCenter
                                color: noteDelArea.containsMouse
                                    ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.85)
                                    : "transparent"
                                opacity: dragArea.containsMouse || cardItem.isSelected ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: Theme.durFast } }

                                Text {
                                    anchors.centerIn: parent
                                    text: "×"
                                    color: noteDelArea.containsMouse ? "#ffffff" : Theme.text3
                                    font.family: Theme.familyBody
                                    font.pixelSize: 12
                                    font.weight: Font.Bold
                                }
                                MouseArea {
                                    id: noteDelArea
                                    anchors.fill: parent
                                    anchors.margins: -3
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.deleteStepRequested(cardItem.stepIdx)
                                }
                            }
                        }

                        Text {
                            width: parent.width
                            text: cardItem.act
                                ? (cardItem.act.value || "(empty)")
                                : ""
                            color: Theme.text2
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            font.italic: true
                            wrapMode: Text.Wrap
                        }
                    }

                    Column {
                        id: cardBody
                        visible: !cardItem.isNote
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
                                width: parent.width - rewireBtn.width - numBadge.width - statusDot.width - deleteBtn.width - parent.spacing * 4
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

                            // Quick-delete. Hover-revealed × pill at
                            // the right edge of the header row,
                            // mirroring the rewire button on the left.
                            // Click removes the step immediately —
                            // mirrors the rail's hover-controls × .
                            Rectangle {
                                id: deleteBtn
                                width: 22; height: 22; radius: 11
                                anchors.verticalCenter: parent.verticalCenter
                                color: deleteArea.containsMouse
                                    ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.85)
                                    : Theme.surface3
                                border.color: deleteArea.containsMouse ? Theme.err : Theme.lineSoft
                                border.width: 1
                                opacity: dragArea.containsMouse || cardItem.isSelected ? 1 : 0
                                Behavior on opacity { NumberAnimation { duration: Theme.durFast } }
                                Behavior on color { ColorAnimation { duration: Theme.durFast } }

                                Text {
                                    anchors.centerIn: parent
                                    text: "×"
                                    color: deleteArea.containsMouse ? "#ffffff" : Theme.text2
                                    font.family: Theme.familyBody
                                    font.pixelSize: 14
                                    font.weight: Font.Bold
                                }
                                MouseArea {
                                    id: deleteArea
                                    anchors.fill: parent
                                    anchors.margins: -4
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.deleteStepRequested(cardItem.stepIdx)
                                    ToolTip.visible: containsMouse
                                    ToolTip.delay: 400
                                    ToolTip.text: "Delete step"
                                }
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

                        // "→ open" affordance for `use` cards. Click
                        // emits openUseRequested(stepIndex) which the
                        // page resolves through the workflow's
                        // imports map and routes up as
                        // openFragmentRequested(absPath, name).
                        Rectangle {
                            visible: cardItem.rawKind === "use"
                            width: parent.width
                            height: 26
                            radius: 6
                            color: openUseArea.containsMouse
                                ? Theme.accentWash(0.18)
                                : Theme.surface3
                            border.color: openUseArea.containsMouse
                                ? Theme.accent
                                : Theme.lineSoft
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: Theme.durFast } }
                            Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

                            Row {
                                anchors.centerIn: parent
                                spacing: 6
                                Text {
                                    text: "→"
                                    color: openUseArea.containsMouse ? Theme.accent : Theme.text2
                                    font.family: Theme.familyBody
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    text: "open import"
                                    color: openUseArea.containsMouse ? Theme.accent : Theme.text2
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontXs
                                    font.weight: Font.Medium
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                id: openUseArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.openUseRequested(cardItem.stepIdx)
                            }
                        }

                        // Inner-step drop zone for flow-control
                        // containers (when / unless / repeat). The
                        // outer Rectangle is what palette drags hit-
                        // test against; its border highlights when a
                        // drag is hovering this container so the
                        // user sees they're about to drop into it.
                        // Inside, the actual inner steps render as
                        // thin rows + a +Add inner-step pill.
                        Rectangle {
                            id: innerZone
                            visible: cardItem.isContainer
                            width: parent.width
                            // Min 92px so an empty container still
                            // reads as a real drop target. When
                            // inner steps land, height grows with
                            // the strip + the +Add pill.
                            height: visible
                                ? Math.max(92, innerStrip.implicitHeight + 28)
                                : 0
                            radius: 8
                            color: cardItem.isHoverDropTarget
                                ? Theme.accentWash(0.14)
                                : Theme.bg
                            border.color: cardItem.isHoverDropTarget
                                ? Theme.accent
                                : Theme.lineSoft
                            border.width: cardItem.isHoverDropTarget ? 2 : 1
                            Behavior on color { ColorAnimation { duration: Theme.durFast } }
                            Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

                            Text {
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.leftMargin: 10
                                anchors.topMargin: 6
                                text: "INNER STEPS  ·  " + innerStrip.inner.length
                                color: cardItem.isHoverDropTarget ? Theme.accent : Theme.text3
                                font.family: Theme.familyBody
                                font.pixelSize: 9
                                font.weight: Font.Bold
                                font.letterSpacing: 0.8
                            }

                            // "Open →" enters this container as the
                            // canvas root. Selection is cleared by
                            // the page; a breadcrumb above the canvas
                            // surfaces the depth and lets the user
                            // climb back. Tinted with the container's
                            // category color so it reads as the
                            // container's own action, not generic
                            // chrome.
                            Rectangle {
                                id: openContainer
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.rightMargin: 8
                                anchors.topMargin: 4
                                width: openLabel.implicitWidth + 22
                                height: 22
                                radius: 4
                                color: openArea.containsMouse
                                    ? Theme.wash(Theme.catFor(cardItem.kind), 0.30)
                                    : Theme.wash(Theme.catFor(cardItem.kind), 0.15)
                                border.color: Theme.catFor(cardItem.kind)
                                border.width: 1
                                Behavior on color { ColorAnimation { duration: Theme.durFast } }

                                Text {
                                    id: openLabel
                                    anchors.centerIn: parent
                                    text: "Open →"
                                    color: Theme.catFor(cardItem.kind)
                                    font.family: Theme.familyBody
                                    font.pixelSize: 10
                                    font.weight: Font.Bold
                                    font.letterSpacing: 0.4
                                }

                                MouseArea {
                                    id: openArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    ToolTip.text: "Open this container in a nested view"
                                    ToolTip.visible: containsMouse
                                    ToolTip.delay: 600
                                    onClicked: root.openContainerRequested(cardItem.stepIdx)
                                }
                            }

                            // Empty-state placeholder. Hidden once
                            // any inner step lands. Highlights to
                            // the kind's accent during a palette
                            // drag for a stronger drop affordance.
                            Text {
                                visible: innerStrip.inner.length === 0
                                anchors.centerIn: parent
                                text: cardItem.isHoverDropTarget
                                    ? "↓  Release to add"
                                    : "Drop a chip here"
                                color: cardItem.isHoverDropTarget ? Theme.accent : Theme.text3
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontSm
                                font.italic: !cardItem.isHoverDropTarget
                                font.weight: cardItem.isHoverDropTarget ? Font.DemiBold : Font.Medium
                            }

                        Column {
                            id: innerStrip
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            anchors.topMargin: 22
                            spacing: 3

                            readonly property var inner: {
                                const ra = cardItem.act ? cardItem.act.rawAction : null
                                return (ra && ra.steps) ? ra.steps : []
                            }

                            Repeater {
                                model: innerStrip.inner
                                delegate: Rectangle {
                                    readonly property bool isInnerSelected:
                                        root.selectedIndex === cardItem.stepIdx
                                        && root.selectedInnerIndex === model.index
                                    width: parent.width
                                    height: 26
                                    radius: 5
                                    color: isInnerSelected
                                        ? Theme.accentWash(0.18)
                                        : (innerHover.containsMouse ? Theme.surface3 : Theme.bg)
                                    border.color: isInnerSelected ? Theme.accent : Theme.lineSoft
                                    border.width: isInnerSelected ? 1.5 : 1
                                    Behavior on color { ColorAnimation { duration: Theme.durFast } }
                                    Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

                                    Row {
                                        anchors.fill: parent
                                        anchors.leftMargin: 8
                                        anchors.rightMargin: 4
                                        spacing: 6

                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: String(model.index + 1).padStart(2, "0")
                                            color: Theme.text3
                                            font.family: Theme.familyMono
                                            font.pixelSize: 9
                                            width: 14
                                        }
                                        CategoryIcon {
                                            anchors.verticalCenter: parent.verticalCenter
                                            kind: _innerKindFor(modelData)
                                            size: 14
                                            hovered: false
                                        }
                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: parent.width - 14 - 6 - 14 - 6 - 22 - 6
                                            text: _innerSummary(modelData)
                                            color: Theme.text2
                                            font.family: Theme.familyBody
                                            font.pixelSize: 10
                                            elide: Text.ElideRight
                                        }
                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 18; height: 18; radius: 3
                                            color: innerDelArea.containsMouse
                                                ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.18)
                                                : "transparent"
                                            Text {
                                                anchors.centerIn: parent
                                                text: "×"
                                                color: innerDelArea.containsMouse ? Theme.err : Theme.text3
                                                font.family: Theme.familyBody
                                                font.pixelSize: 12
                                            }
                                            MouseArea {
                                                id: innerDelArea
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.deleteInnerStepRequested(cardItem.stepIdx, model.index)
                                            }
                                        }
                                    }

                                    MouseArea {
                                        id: innerHover
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.selectInnerStep(cardItem.stepIdx, model.index)
                                    }
                                }
                            }

                            // Add-inner pill — dashed border so it
                            // reads as an empty drop zone rather than
                            // an action card. Click opens the kind
                            // picker.
                            Rectangle {
                                width: parent.width
                                height: 22
                                radius: 5
                                color: addInnerArea.containsMouse ? Theme.surface3 : "transparent"
                                border.color: Theme.lineSoft
                                border.width: 1

                                Row {
                                    anchors.centerIn: parent
                                    spacing: 4
                                    Text {
                                        text: "+"
                                        color: cardItem.cardBg === Theme.surface2
                                            ? Theme.accent : Theme.text2
                                        font.family: Theme.familyBody
                                        font.pixelSize: 12
                                        font.weight: Font.Bold
                                    }
                                    Text {
                                        text: "inner step"
                                        color: Theme.text3
                                        font.family: Theme.familyBody
                                        font.pixelSize: 9
                                        font.letterSpacing: 0.5
                                    }
                                }

                                MouseArea {
                                    id: addInnerArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: addInnerCanvasMenu.popup()
                                }

                                WfMenu {
                                    id: addInnerCanvasMenu
                                    Repeater {
                                        model: [
                                            { kind: "key",       label: "Key chord"    },
                                            { kind: "type",      label: "Type text"    },
                                            { kind: "click",     label: "Click"        },
                                            { kind: "focus",     label: "Focus window" },
                                            { kind: "wait",      label: "Wait"         },
                                            { kind: "shell",     label: "Shell"        },
                                            { kind: "notify",    label: "Notify"       },
                                            { kind: "clipboard", label: "Clipboard"    },
                                            { kind: "note",      label: "Note"         }
                                        ]
                                        delegate: WfMenuItem {
                                            text: modelData.label
                                            onTriggered: root.addInnerStepRequested(cardItem.stepIdx, modelData.kind)
                                        }
                                    }
                                }
                            }
                        }
                        }   // end of innerZone Rectangle
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
    // Parented to Overlay.overlay (the top-of-window layer Popups use),
    // so the ghost reliably renders above every card / container —
    // a sibling Rectangle at z:200 in the canvas root looked right on
    // paper but practical scene-graph behaviour kept tucking the
    // ghost under cards inside the Flickable. Scene-space coords mean
    // no mapping is needed: chip.mapToItem(null, …) gives scene-space
    // directly. Scale tracks root.zoom so the ghost matches the size
    // a dropped card would render at on the canvas.
    Rectangle {
        parent: Overlay.overlay
        visible: root.ghostActive
        transformOrigin: Item.Center
        scale: root.zoom
        x: root.ghostX - root.nodeW / 2
        y: root.ghostY - root.nodeMinH / 2
        width: root.nodeW
        height: root.nodeMinH
        z: 10000
        opacity: 0.85
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
    function _routeWire(fromPos, toPos, fromH, toH, fromW, toW) {
        if (!fromPos || !toPos) return { sx: 0, sy: 0, tx: 0, ty: 0, axis: "v" }
        if (!fromW) fromW = nodeW
        if (!toW)   toW   = nodeW
        const fromCx = fromPos.x + fromW / 2
        const fromCy = fromPos.y + fromH / 2
        const toCx = toPos.x + toW / 2
        const toCy = toPos.y + toH / 2

        const xOverlap = !(fromPos.x + fromW <= toPos.x || toPos.x + toW <= fromPos.x)
        const yOverlap = !(fromPos.y + fromH <= toPos.y || toPos.y + toH <= fromPos.y)

        let useVertical
        if (yOverlap && !xOverlap) {
            useVertical = false
        } else if (xOverlap && !yOverlap) {
            useVertical = true
        } else if (!xOverlap && !yOverlap) {
            useVertical = true
        } else {
            const dx = toCx - fromCx
            const dy = toCy - fromCy
            useVertical = Math.abs(dy) >= Math.abs(dx)
        }

        if (!useVertical) {
            if (toCx > fromCx) {
                return { sx: fromPos.x + fromW, sy: fromCy, tx: toPos.x,        ty: toCy, axis: "h" }
            } else {
                return { sx: fromPos.x,         sy: fromCy, tx: toPos.x + toW,  ty: toCy, axis: "h" }
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

    // Map a raw KDL action kind (the strings used in actions.rs) to
    // the shaped kind string the rest of the canvas / CategoryIcon
    // expects. Inner steps inside containers carry the raw form, so
    // we project here for display purposes.
    function _shapedFromRaw(rawKind) {
        switch (rawKind) {
        case "wdo_type":            return "type"
        case "wdo_key":
        case "wdo_key_down":
        case "wdo_key_up":          return "key"
        case "wdo_click":
        case "wdo_mouse_down":
        case "wdo_mouse_up":        return "click"
        case "wdo_mouse_move":      return "move"
        case "wdo_scroll":          return "scroll"
        case "wdo_activate_window": return "focus"
        case "wdo_await_window":
        case "delay":               return "wait"
        case "shell":               return "shell"
        case "notify":              return "notify"
        case "clipboard":           return "clipboard"
        case "note":                return "note"
        case "repeat":              return "repeat"
        case "conditional":         return "when"
        case "use":                 return "use"
        }
        return "wait"
    }

    function _innerKindFor(step) {
        const a = step ? step.action : null
        return _shapedFromRaw(a ? a.kind : "")
    }

    function _innerSummary(step) {
        const a = step ? step.action : null
        if (!a) return ""
        const k = a.kind
        switch (k) {
        case "wdo_type":            return a.text || "(empty)"
        case "wdo_key":
        case "wdo_key_down":
        case "wdo_key_up":          return a.chord || ""
        case "wdo_click":
        case "wdo_mouse_down":
        case "wdo_mouse_up":        return "button " + (a.button !== undefined ? a.button : 1)
        case "wdo_mouse_move":      return "(" + (a.x || 0) + ", " + (a.y || 0) + ")"
        case "wdo_scroll":          return "dx " + (a.dx || 0) + "  dy " + (a.dy || 0)
        case "wdo_activate_window": return a.name || ""
        case "wdo_await_window":    return a.name || ""
        case "delay":               return (a.ms || 0) + " ms"
        case "shell":               return (a.command || "").slice(0, 32)
        case "notify":              return a.title || ""
        case "clipboard":           return (a.text || "").slice(0, 28)
        case "note":                return (a.text || "").slice(0, 28)
        case "repeat":              return "× " + (a.count || 1)
        case "conditional":         return (a.negate ? "unless" : "when")
        case "use":                 return a.name || ""
        }
        return ""
    }
}
