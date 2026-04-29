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
    // Multi-selection set, keyed by stringified index. Cards check
    // both this and selectedIndex so callers that don't wire up the
    // map keep working with the legacy single-select semantics.
    property var selectedIndices: ({})
    property int activeStepIndex: -1
    // Companion to activeStepIndex — if the active step is INNER
    // (an inner step of a conditional), this is the actions index of
    // the parent conditional. Card delegates check both so the
    // conditional card pulses while its inner step is running.
    property int activeParentIndex: -1
    property var stepStatuses: ({})
    // Same statuses keyed by stable step_id, so inner steps inside a
    // repeat container (which don't surface as top-level cards) can
    // resolve their own dot colour.
    property var stepStatusesById: ({})
    // The id of the step the engine is currently running. Used by
    // inner step rows to pulse their dot green.
    property string activeStepId: ""
    // Visual annotation rectangles drawn behind the step cards. Each
    // entry: { id, x, y, width, height, color, comment }.
    property var groups: []

    // Shared marquee state for the Shift / Ctrl drag handlers. Lives
    // here so the on-screen rect can read from one source regardless
    // of which modifier fired the drag. Coordinates are stored in
    // WORLD space (logical, pre-zoom) so they line up with each
    // card's own x/y for hit-testing without further conversion.
    property bool _marqueeActive: false
    property real _marqueeStartX: 0
    property real _marqueeStartY: 0
    property real _marqueeCurrentX: 0
    property real _marqueeCurrentY: 0
    readonly property real _marqueeLeft:   Math.min(_marqueeStartX, _marqueeCurrentX)
    readonly property real _marqueeTop:    Math.min(_marqueeStartY, _marqueeCurrentY)
    readonly property real _marqueeRight:  Math.max(_marqueeStartX, _marqueeCurrentX)
    readonly property real _marqueeBottom: Math.max(_marqueeStartY, _marqueeCurrentY)

    // Map a DragHandler's centroid scene position into WORLD coords.
    // Going via scenePosition + world.mapFromItem dodges any
    // ambiguity about which Item the handler's centroid.position is
    // local to (Flickable vs. its contentItem) and correctly accounts
    // for scroll offset + zoom in one shot.
    function _handlerToWorld(handler) {
        const sp = handler.centroid.scenePosition
        return world.mapFromItem(null, sp.x, sp.y)
    }

    function _marqueeOnActiveChanged(handler) {
        if (handler.active) {
            const w = _handlerToWorld(handler)
            _marqueeStartX = w.x
            _marqueeStartY = w.y
            _marqueeCurrentX = w.x
            _marqueeCurrentY = w.y
            _marqueeActive = true
        } else {
            _marqueeActive = false
            _commitMarqueeSelection(
                _marqueeLeft, _marqueeTop, _marqueeRight, _marqueeBottom)
        }
    }
    function _marqueeOnCentroidChanged(handler) {
        if (!handler.active) return
        const w = _handlerToWorld(handler)
        _marqueeCurrentX = w.x
        _marqueeCurrentY = w.y
    }

    // Reactive position / size stores. Each card writes into these
    // on drag-release and on size-change; wires + hit-tests read
    // from them. Width is per-card so containers (which are wider
    // than action cards) get correct wire endpoints + drop bounds.
    property var positions: ({})    // { [id]: {x, y} }
    property var cardHeights: ({})  // { [id]: number }
    property var cardWidths: ({})   // { [id]: number }

    // Width a given step should render at — derived from the shaped
    // action's rawKind. Repeat is wider because its inner-step drop
    // zone needs a meaningful footprint; conditionals (when/unless)
    // are now narrower decision-card shapes since their inner steps
    // surface as siblings on the canvas. Notes are narrower since
    // they're annotations, not first-class operations.
    function _widthForKind(rawKind) {
        if (rawKind === "repeat") return containerW
        if (rawKind === "conditional") return conditionalW
        if (rawKind === "note") return noteW
        return nodeW
    }

    // Resolve a group's color name to a Theme color. Recognised
    // names mirror the category palette plus a couple of muted
    // neutrals; unknown names fall back to accent so a user-typed
    // color in the KDL file doesn't render as an invisible group.
    function _groupColorFor(name) {
        switch (name) {
        case "key":       return Theme.catKey
        case "type":      return Theme.catType
        case "click":     return Theme.catClick
        case "move":      return Theme.catMove
        case "scroll":    return Theme.catScroll
        case "focus":     return Theme.catFocus
        case "shell":     return Theme.catShell
        case "notify":    return Theme.catNotify
        case "clipboard": return Theme.catClip
        case "wait":      return Theme.catWait
        case "neutral":   return Theme.text2
        case "accent":    return Theme.accent
        }
        return Theme.accent
    }

    // Alt+drag committed: emit a request to add a new group at the
    // dragged-out rect. Coords are already world-local. Tiny drags
    // are ignored as misclicks; the threshold scales inversely with
    // zoom so a small on-screen wiggle doesn't fail at 200% zoom.
    function _commitDrawGroup(wL, wT, wR, wB) {
        const minSpan = 24 / Math.max(0.01, root.zoom)
        if ((wR - wL) < minSpan || (wB - wT) < minSpan) return
        root.addGroupRequested(wL, wT, wR - wL, wB - wT)
    }

    // Drop a default-sized group at the current viewport center.
    // Used by the canvas tool dock's '▢ Add group' button so users
    // who don't know about Alt+drag can still reach the feature.
    function _addGroupAtViewportCenter() {
        const z = root.zoom > 0 ? root.zoom : 1
        const w = 320
        const h = 200
        const cx = (flick.contentX + flick.width  / 2) / z
        const cy = (flick.contentY + flick.height / 2) / z
        root.addGroupRequested(cx - w / 2, cy - h / 2, w, h)
    }

    // Walk every visible card and find which rectangles intersect
    // the marquee rect. Coordinates come in WORLD space (already
    // unprojected from the handler's centroid via _handlerToWorld);
    // card x/y are also world-local, so this is a plain AABB overlap
    // test with no further conversion. Empty-marquee guard uses
    // a small minimum span to avoid stray micro-drags.
    function _commitMarqueeSelection(wL, wT, wR, wB) {
        const minSpan = 4 / Math.max(0.01, root.zoom)
        if ((wR - wL) < minSpan || (wB - wT) < minSpan) return

        // Prefer card rects from positions/cardWidths/cardHeights
        // (the source of truth) and fall back to the live delegate
        // when the maps haven't caught up. Either way, all values
        // are world-local.
        const next = ({})
        const acts = root.actions || []
        for (let i = 0; i < acts.length; i++) {
            const a = acts[i]
            if (!a) continue
            const p = root.positions[a.id]
            const cw = root.cardWidths[a.id] || _widthForKind(a.rawKind)
            const ch = root.cardHeights[a.id] || nodeMinH
            let cx, cy
            if (p) {
                cx = p.x; cy = p.y
            } else {
                const card = nodeRep.itemAt(i)
                if (!card) continue
                cx = card.x; cy = card.y
            }
            if (cx + cw > wL && cx < wR && cy + ch > wT && cy < wB) {
                next[i] = true
            }
        }
        if (Object.keys(next).length > 0) {
            root.marqueeSelected(next)
        }
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

    // Fired by the page on every wfCtrl.step_started — used by inner
    // step rows in repeat containers to flash on each iteration even
    // when active_step_id stays unchanged across the loop.
    signal stepStarted(string stepId)

    signal selectStep(int index)
    // Modifier-aware variants for shift / ctrl-click selection.
    signal rangeSelectStep(int index)
    signal toggleSelectStep(int index)
    // Shift+drag rectangle on empty canvas committed: emits the new
    // selectedIndices set the page should adopt. Page replaces the
    // current selection with this set rather than merging because
    // Replace is the most-expected semantics for marquee.
    signal marqueeSelected(var indicesSet)
    signal deselectRequested()

    // Group rectangle interactions.
    signal addGroupRequested(real x, real y, real width, real height)
    signal moveGroupRequested(string id, real x, real y)
    signal resizeGroupRequested(string id, real x, real y, real width, real height)
    signal deleteGroupRequested(string id)
    signal editGroupCommentRequested(string id, string comment)
    signal editGroupColorRequested(string id, string color)
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
    // Option flip from a card's right-click menu (currently:
    // enable/skip toggle). Routed to WorkflowPage's _commitOption.
    signal optionEdited(int stepIndex, string path, var value)
    // Rewire from a card's overflow menu — `stepIndex` is the card
    // that's being rewired, `otherIndex` is the chosen counterpart.
    // The page resolves these via _moveStep.
    signal predecessorChosen(int stepIndex, int otherIndex)
    signal successorChosen(int stepIndex, int otherIndex)

    readonly property int nodeW: 260
    readonly property int containerW: 360
    readonly property int conditionalW: 300
    readonly property int noteW: 200
    readonly property int nodeMinH: 132
    readonly property int conditionalMinH: 156
    readonly property int noteMinH: 56
    readonly property int gap: 36
    readonly property int _portR: 6

    // Pairs of step indices that should be connected by a wire.
    // Notes are annotations (engine skips them), so wires bridge
    // over them — the previous operational step connects directly
    // to the next operational step. Computed once per actions
    // change; the wire Repeater uses this as its model.
    readonly property var _wirePairs: {
        const arr = root.actions || []
        const out = []

        // Helper: index in `arr` of a conditional's FIRST NON-NOTE
        // inner step (notes are annotations and shouldn't anchor a
        // wire). -1 if no operational inner exists.
        function firstInnerOf(parentTopIdx) {
            let best = -1
            let bestJ = Number.MAX_SAFE_INTEGER
            for (let i = 0; i < arr.length; i++) {
                const it = arr[i]
                if (!it) continue
                if (it._displayKind === "inner"
                    && it._parentTopIdx === parentTopIdx
                    && it.rawKind !== "note"
                    && it._innerIdx < bestJ) {
                    best = i
                    bestJ = it._innerIdx
                }
            }
            return best
        }

        // Helper: index in `arr` of a conditional's LAST NON-NOTE
        // inner step.
        function lastInnerOf(parentTopIdx) {
            let best = -1
            let bestJ = -1
            for (let i = 0; i < arr.length; i++) {
                const it = arr[i]
                if (!it) continue
                if (it._displayKind === "inner"
                    && it._parentTopIdx === parentTopIdx
                    && it.rawKind !== "note"
                    && it._innerIdx > bestJ) {
                    best = i
                    bestJ = it._innerIdx
                }
            }
            return best
        }

        // Helper: next non-note "top" item index after `topIdx`.
        function nextTopAfter(topIdx) {
            for (let i = 0; i < arr.length; i++) {
                const it = arr[i]
                if (!it) continue
                if (it._displayKind !== "top") continue
                if (it.rawKind === "note") continue
                if (it._topIdx > topIdx) return i
            }
            return -1
        }

        for (let i = 0; i < arr.length; i++) {
            const it = arr[i]
            if (!it) continue
            if (it.rawKind === "note") continue

            if (it._displayKind === "top") {
                if (it.rawKind === "conditional") {
                    // Branch: yes → first inner, no/skip → next top.
                    const first = firstInnerOf(it._topIdx)
                    const last = lastInnerOf(it._topIdx)
                    const nextTop = nextTopAfter(it._topIdx)
                    if (first >= 0) {
                        out.push({ from: i, to: first, label: "yes" })
                    }
                    if (nextTop >= 0) {
                        // The "no/skip" wire only renders when the
                        // conditional has at least one inner step;
                        // otherwise the conditional itself acts as a
                        // single-edge passthrough and the next-top
                        // wire below handles it.
                        if (first >= 0) {
                            out.push({ from: i, to: nextTop, label: "no" })
                        } else {
                            out.push({ from: i, to: nextTop })
                        }
                    }
                    // Last inner reconnects to the next-top so the
                    // yes-branch path rejoins the main flow.
                    if (last >= 0 && nextTop >= 0) {
                        out.push({ from: last, to: nextTop })
                    }
                } else {
                    // Plain top step — wire to next top (notes
                    // skipped via the helper).
                    const nextTop = nextTopAfter(it._topIdx)
                    if (nextTop >= 0) out.push({ from: i, to: nextTop })
                }
            } else if (it._displayKind === "inner") {
                // Inner step: chain to the next NON-NOTE inner of
                // the same parent, if any. Notes are annotations —
                // wires bridge over them just like at the top level.
                // If this is the last inner, the conditional's
                // `top` branch above already added the rejoin wire.
                let bestJ = Number.MAX_SAFE_INTEGER
                let bestK = -1
                for (let j = 0; j < arr.length; j++) {
                    const next = arr[j]
                    if (!next) continue
                    if (next._displayKind !== "inner") continue
                    if (next._parentTopIdx !== it._parentTopIdx) continue
                    if (next.rawKind === "note") continue
                    if (next._innerIdx > it._innerIdx
                        && next._innerIdx < bestJ) {
                        bestJ = next._innerIdx
                        bestK = j
                    }
                }
                if (bestK >= 0) out.push({ from: i, to: bestK })
            }
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

    // Helper: items whose displayKind/parent matches.
    function _innerOf(list, parentTopIdx) {
        return list.filter(it => it && it._displayKind === "inner"
            && it._parentTopIdx === parentTopIdx)
            .sort((a, b) => a._innerIdx - b._innerIdx)
    }

    function organizeVertical() {
        // Main flow runs down a centre column. Conditional branches
        // fan to the RIGHT in a parallel column. Per the design:
        // the first inner card's TOP edge aligns with the parent
        // conditional's vertical midpoint, and the last inner card's
        // BOTTOM edge aligns with the next-top's vertical midpoint —
        // so the wires fork from / rejoin to the cards' midpoints.
        const list = root.actions || []
        const tops = list.filter(it => it && it._displayKind === "top")
        if (tops.length === 0) return

        // Pick the centreline X so every top card centres on it, and
        // the branch column lives well clear of the widest top card.
        let maxTopW = nodeW
        for (const t of tops) {
            const w = cardWidths[t.id] || _widthForKind(t.rawKind)
            if (w > maxTopW) maxTopW = w
        }
        const centerX = paddingLeft + maxTopW / 2 + nodeW
        // Branch column is LEFT-anchored at the right edge of the main
        // column + a generous gap, so wide inner cards never extend back
        // into the main column regardless of their width.
        const topRightEdge = centerX + maxTopW / 2
        const branchLeft = topRightEdge + gap * 2

        const next = {}
        let y = paddingTop
        for (let i = 0; i < tops.length; i++) {
            const it = tops[i]
            const w = cardWidths[it.id] || _widthForKind(it.rawKind)
            const h = cardHeights[it.id] || nodeMinH
            next[it.id] = { x: centerX - w / 2, y: y }

            let nextY = y + h + gap

            if (it.rawKind === "conditional") {
                const inner = _innerOf(list, it._topIdx)
                    .filter(ic => ic.rawKind !== "note")
                if (inner.length > 0) {
                    // First inner: top edge at when's midpoint.
                    const branchTopY = y + h / 2
                    let innerY = branchTopY
                    let innerSpan = 0
                    for (let k = 0; k < inner.length; k++) {
                        const ic = inner[k]
                        const iw = cardWidths[ic.id] || _widthForKind(ic.rawKind)
                        const ih = cardHeights[ic.id] || nodeMinH
                        next[ic.id] = { x: branchLeft, y: innerY }
                        innerY += ih
                        innerSpan += ih
                        if (k < inner.length - 1) {
                            innerY += gap
                            innerSpan += gap
                        }
                    }
                    // Place next top so its midpoint lines up with
                    // the last inner's bottom — the rejoin lands on
                    // the next-top's centre. Use an estimated
                    // height for the next top (same as ours) since
                    // it isn't laid out yet.
                    const branchEndY = branchTopY + innerSpan
                    const nextTop = i + 1 < tops.length ? tops[i + 1] : null
                    const nextH = nextTop
                        ? (cardHeights[nextTop.id] || nodeMinH)
                        : nodeMinH
                    nextY = Math.max(y + h + gap, branchEndY - nextH / 2)
                }
            }

            y = nextY
        }
        positions = next
        Qt.callLater(_zoomToFit)
    }

    function organizeHorizontal() {
        // Main flow runs left-to-right along a centre row. Conditional
        // branches drop BELOW the parent in a parallel row that
        // starts at when's horizontal midpoint and ends at the next-
        // top's horizontal midpoint.
        const list = root.actions || []
        const tops = list.filter(it => it && it._displayKind === "top")
        if (tops.length === 0) return

        let maxTopH = nodeMinH
        for (const t of tops) {
            const h = cardHeights[t.id] || nodeMinH
            if (h > maxTopH) maxTopH = h
        }
        const centerY = paddingTop + maxTopH / 2 + nodeMinH / 2
        const branchY = centerY + maxTopH / 2 + gap * 2

        const next = {}
        let x = paddingLeft
        for (let i = 0; i < tops.length; i++) {
            const it = tops[i]
            const w = cardWidths[it.id] || _widthForKind(it.rawKind)
            const h = cardHeights[it.id] || nodeMinH
            next[it.id] = { x: x, y: centerY - h / 2 }

            let nextX = x + w + gap

            if (it.rawKind === "conditional") {
                const inner = _innerOf(list, it._topIdx)
                    .filter(ic => ic.rawKind !== "note")
                if (inner.length > 0) {
                    const branchStartX = x + w / 2
                    let innerX = branchStartX
                    let innerSpan = 0
                    for (let k = 0; k < inner.length; k++) {
                        const ic = inner[k]
                        const iw = cardWidths[ic.id] || _widthForKind(ic.rawKind)
                        const ih = cardHeights[ic.id] || nodeMinH
                        next[ic.id] = { x: innerX, y: branchY - ih / 2 }
                        innerX += iw
                        innerSpan += iw
                        if (k < inner.length - 1) {
                            innerX += gap
                            innerSpan += gap
                        }
                    }
                    const branchEndX = branchStartX + innerSpan
                    const nextTop = i + 1 < tops.length ? tops[i + 1] : null
                    const nextW = nextTop
                        ? (cardWidths[nextTop.id] || _widthForKind(nextTop.rawKind))
                        : nodeW
                    nextX = Math.max(x + w + gap, branchEndX - nextW / 2)
                }
            }

            x = nextX
        }
        positions = next
        Qt.callLater(_zoomToFit)
    }
    function organizeGrid() {
        // Grid lays out top-level cards in a square-ish footprint.
        // Conditional branch cards stack DIRECTLY BELOW their parent
        // in the same grid cell (rather than to the right) so the
        // no-wire from the parent to the next-top can travel along
        // the row unobstructed by branch cards.
        const list = root.actions || []
        if (list.length === 0) return
        const tops = list.filter(it => it && it._displayKind === "top")
        if (tops.length === 0) return

        const cols = Math.max(1, Math.ceil(Math.sqrt(tops.length)))

        // Cell footprint = top card + branch column underneath.
        // Column width = max top width across cells in that column.
        // Row height = max (top.h + branch column total height) across cells.
        const colWidths = []
        const rowHeights = []
        for (let i = 0; i < tops.length; i++) {
            const a = tops[i]
            const col = i % cols
            const row = Math.floor(i / cols)
            const w = cardWidths[a.id] || _widthForKind(a.rawKind)
            let cellH = cardHeights[a.id] || nodeMinH
            if (a.rawKind === "conditional") {
                const inner = _innerOf(list, a._topIdx)
                    .filter(ic => ic.rawKind !== "note")
                let innerSpan = 0
                for (let k = 0; k < inner.length; k++) {
                    innerSpan += cardHeights[inner[k].id] || nodeMinH
                    if (k < inner.length - 1) innerSpan += gap
                }
                if (innerSpan > 0) cellH += gap + innerSpan
            }
            colWidths[col] = Math.max(colWidths[col] || 0, w)
            rowHeights[row] = Math.max(rowHeights[row] || 0, cellH)
        }

        const colX = [paddingLeft]
        for (let c = 1; c < cols; c++) {
            colX.push(colX[c - 1] + colWidths[c - 1] + gap * 2)
        }
        const rowY = [paddingTop]
        for (let r = 1; r < rowHeights.length; r++) {
            rowY.push(rowY[r - 1] + rowHeights[r - 1] + gap * 2)
        }

        const next = {}
        for (let i = 0; i < tops.length; i++) {
            const a = tops[i]
            const col = i % cols
            const row = Math.floor(i / cols)
            const w = cardWidths[a.id] || _widthForKind(a.rawKind)
            const h = cardHeights[a.id] || nodeMinH
            // Centre top card on the column's centreline.
            const centreX = colX[col] + colWidths[col] / 2
            next[a.id] = { x: centreX - w / 2, y: rowY[row] }

            if (a.rawKind === "conditional") {
                const inner = _innerOf(list, a._topIdx)
                    .filter(ic => ic.rawKind !== "note")
                let innerY = rowY[row] + h + gap
                for (const ic of inner) {
                    const iw = cardWidths[ic.id] || _widthForKind(ic.rawKind)
                    const ih = cardHeights[ic.id] || nodeMinH
                    next[ic.id] = { x: centreX - iw / 2, y: innerY }
                    innerY += ih + gap
                }
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

        // Find any item whose position is already set so we can stack
        // unplaced cards beneath the lowest of them. Inner cards
        // (conditional branch steps) get placed offset to the right
        // of their parent so the branch reads visually.
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
            const item = list[i]
            if (next[item.id]) continue
            if (item._displayKind === "inner") {
                // Inner step: position offset to the right of the
                // parent conditional. If the parent isn't placed
                // yet, fall through to the default stack.
                const parent = list.find(it => it && it._displayKind === "top"
                    && it._topIdx === item._parentTopIdx)
                const parentPos = parent ? next[parent.id] : null
                if (parentPos) {
                    const branchX = parentPos.x + nodeW + 80
                    const branchY = parentPos.y + (item._innerIdx * (nodeMinH + gap / 2))
                    next[item.id] = { x: branchX, y: branchY }
                    dirty = true
                    continue
                }
            }
            next[item.id] = { x: paddingLeft, y: maxY }
            maxY += nodeMinH + gap
            dirty = true
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
        // handler takes the gesture and pans. acceptedModifiers
        // restricts pan to bare drags so shift+drag is free for
        // marquee selection.
        DragHandler {
            id: panHandler
            target: null
            acceptedModifiers: Qt.NoModifier
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

        // Shift OR Ctrl + drag on empty canvas draws a marquee
        // rectangle and selects every card whose rect intersects it
        // on release. Cards' own MouseAreas claim presses on
        // themselves first, so this handler only ever runs over the
        // empty backdrop. Coordinates are in flick's local space;
        // the commit step unprojects them through scroll + zoom into
        // world space for hit-testing against card positions.
        //
        // Qt's PointerHandler.acceptedModifiers is an exact match,
        // not a flags-OR, so accepting two different modifiers means
        // two handlers. They share state via root-level marquee*
        // properties so the visualization rect doesn't care which
        // one fired.
        DragHandler {
            id: marqueeHandlerShift
            target: null
            acceptedModifiers: Qt.ShiftModifier
            onActiveChanged: root._marqueeOnActiveChanged(this)
            onCentroidChanged: root._marqueeOnCentroidChanged(this)
        }
        DragHandler {
            id: marqueeHandlerCtrl
            target: null
            acceptedModifiers: Qt.ControlModifier
            onActiveChanged: root._marqueeOnActiveChanged(this)
            onCentroidChanged: root._marqueeOnCentroidChanged(this)
        }

        // Alt+drag on empty canvas draws a NEW group rectangle.
        // Mirrors the marquee handler — coordinates live in WORLD
        // space (already scroll/zoom-corrected) so the visual rect
        // and the commit hit-test agree without further conversion.
        DragHandler {
            id: drawGroupHandler
            target: null
            acceptedModifiers: Qt.AltModifier
            property real startX: 0
            property real startY: 0
            property real currentX: 0
            property real currentY: 0
            readonly property real left:   Math.min(startX, currentX)
            readonly property real top:    Math.min(startY, currentY)
            readonly property real right:  Math.max(startX, currentX)
            readonly property real bottom: Math.max(startY, currentY)

            onActiveChanged: {
                if (active) {
                    const w = root._handlerToWorld(this)
                    startX = w.x
                    startY = w.y
                    currentX = w.x
                    currentY = w.y
                } else {
                    root._commitDrawGroup(left, top, right, bottom)
                }
            }
            onCentroidChanged: {
                if (!active) return
                const w = root._handlerToWorld(this)
                currentX = w.x
                currentY = w.y
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

            // Marquee + draw-group rectangles. Drawn inside `world`
            // because their coordinates are stored in world space —
            // the scale transform handles zoom for us, and the rects
            // stay glued to the underlying cards as the user pans.
            // Border widths are scaled inversely so the on-screen
            // stroke stays a consistent ~1px regardless of zoom.
            Rectangle {
                id: marqueeRect
                visible: root._marqueeActive
                x: root._marqueeLeft
                y: root._marqueeTop
                width: root._marqueeRight - root._marqueeLeft
                height: root._marqueeBottom - root._marqueeTop
                color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.12)
                border.color: Theme.accent
                border.width: 1 / Math.max(0.01, root.zoom)
                radius: 2 / Math.max(0.01, root.zoom)
                z: 50
            }
            Rectangle {
                id: drawGroupRect
                visible: drawGroupHandler.active
                x: drawGroupHandler.left
                y: drawGroupHandler.top
                width: drawGroupHandler.right - drawGroupHandler.left
                height: drawGroupHandler.bottom - drawGroupHandler.top
                color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.10)
                border.color: Theme.accent
                border.width: 1.5 / Math.max(0.01, root.zoom)
                radius: Theme.radiusMd / Math.max(0.01, root.zoom)
                z: 50
            }

            // ============ Group rectangles ============
            // Decorative annotations behind the wires + cards.
            //
            //   - left-click + drag the body  → move the group
            //   - left-click + drag the corner → resize
            //   - double-click the body       → edit the comment
            //   - right-click                 → menu (color / delete)
            //
            // Engine ignores them entirely; they're for visual
            // organisation only.
            Repeater {
                id: groupLayer
                model: root.groups
                delegate: Rectangle {
                    id: groupItem
                    z: 0
                    readonly property string groupId: modelData.id
                    readonly property color tint: _groupColorFor(modelData.color)
                    readonly property bool isHovered: hoverHandler.hovered
                    x: modelData.x
                    y: modelData.y
                    width: modelData.width
                    height: modelData.height
                    radius: Theme.radiusMd
                    color: Qt.rgba(tint.r, tint.g, tint.b,
                        isHovered ? 0.16 : 0.10)
                    border.color: Qt.rgba(tint.r, tint.g, tint.b,
                        isHovered ? 0.85 : 0.50)
                    border.width: isHovered ? 2 : 1.5
                    Behavior on color       { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    Behavior on border.color{ ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    Behavior on border.width{ NumberAnimation { duration: Theme.dur(Theme.durFast) } }

                    HoverHandler { id: hoverHandler }

                    // ---- Body: drag to move ----
                    // MouseArea on the body claims left-press
                    // exclusively (preventStealing) so the canvas
                    // pan handler can't take over mid-drag and
                    // 'pan the canvas' under the user. Right-click
                    // pops the menu; double-click opens the comment
                    // editor.
                    MouseArea {
                        id: bodyArea
                        anchors.fill: parent
                        anchors.rightMargin: resizeHandle.width
                        anchors.bottomMargin: resizeHandle.height
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        cursorShape: drag.active
                            ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                        drag.target: groupItem
                        drag.threshold: 4
                        preventStealing: true
                        onPressed: (mouse) => {
                            if (mouse.button === Qt.RightButton) {
                                groupMenu.popup()
                                mouse.accepted = true
                            }
                        }
                        onReleased: (mouse) => {
                            if (mouse.button === Qt.RightButton) return
                            if (drag.active) {
                                root.moveGroupRequested(
                                    groupItem.groupId, groupItem.x, groupItem.y)
                            }
                        }
                        onDoubleClicked: (mouse) => {
                            if (mouse.button !== Qt.LeftButton) return
                            commentEditor.text = modelData.comment || ""
                            commentEditor.visible = true
                            commentEditor.forceActiveFocus()
                            commentEditor.selectAll()
                        }
                    }

                    // ---- Resize handle (bottom-right corner) ----
                    // Uses a DragHandler with translation rather than
                    // a MouseArea with mouse.x math. translation is
                    // the delta from press position in stable
                    // coordinates, so width / height grow predictably
                    // without the feedback loop the previous version
                    // had.
                    Item {
                        id: resizeHandle
                        width: 18
                        height: 18
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        z: 2

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 4
                            color: groupItem.isHovered
                                ? Qt.rgba(groupItem.tint.r, groupItem.tint.g, groupItem.tint.b, 0.85)
                                : Qt.rgba(groupItem.tint.r, groupItem.tint.g, groupItem.tint.b, 0.50)
                            radius: 2
                            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                        }
                        DragHandler {
                            id: resizeHandler
                            target: null
                            grabPermissions: PointerHandler.TakeOverForbidden
                            cursorShape: Qt.SizeFDiagCursor
                            property real _startW: 0
                            property real _startH: 0
                            onActiveChanged: {
                                if (active) {
                                    _startW = groupItem.width
                                    _startH = groupItem.height
                                } else {
                                    root.resizeGroupRequested(
                                        groupItem.groupId,
                                        groupItem.x, groupItem.y,
                                        groupItem.width, groupItem.height)
                                }
                            }
                            onTranslationChanged: {
                                if (!active) return
                                groupItem.width = Math.max(120, _startW + translation.x)
                                groupItem.height = Math.max(80, _startH + translation.y)
                            }
                        }
                    }

                    // ---- Comment label, upper-left ----
                    // Double-click ANYWHERE in the body opens the
                    // editor (handled in bodyArea above) — no
                    // separate MouseArea over the label, so the
                    // body's drag isn't blocked when the user clicks
                    // through the label area.
                    // Read-only label. Wraps so multi-line comments
                    // render across the top of the group; Enter on
                    // its own line breaks visually like the editor's
                    // input.
                    Text {
                        id: groupComment
                        visible: !commentEditor.visible
                        text: modelData.comment && modelData.comment.length > 0
                            ? modelData.comment
                            : "Double-click to name"
                        color: groupItem.tint
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontXs
                        font.weight: Font.Bold
                        font.letterSpacing: 1.2
                        font.capitalization: modelData.comment && modelData.comment.length > 0
                            ? Font.MixedCase
                            : Font.AllUppercase
                        wrapMode: Text.WordWrap
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.leftMargin: 12
                        anchors.topMargin: 8
                        anchors.rightMargin: resizeHandle.width + 4
                        opacity: modelData.comment && modelData.comment.length > 0
                            ? 1 : 0.50
                    }

                    // Multi-line editor: TextEdit (not TextInput) so
                    // Enter inserts a newline. Plain Enter no longer
                    // commits — Esc and focus-loss do — because the
                    // expected mental model for a labelled box is
                    // "type, get out by clicking elsewhere," like the
                    // step inspector's text fields.
                    TextEdit {
                        id: commentEditor
                        visible: false
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.leftMargin: 12
                        anchors.topMargin: 6
                        anchors.rightMargin: resizeHandle.width + 4
                        text: modelData.comment || ""
                        color: groupItem.tint
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.Medium
                        wrapMode: TextEdit.WordWrap
                        selectByMouse: true
                        z: 3   // above bodyArea so typing doesn't bleed through
                        onActiveFocusChanged: if (!activeFocus && visible) _commit()
                        function _commit() {
                            root.editGroupCommentRequested(
                                groupItem.groupId, text)
                            visible = false
                        }
                        // Escape commits the buffer too. Hiding before
                        // calling _commit would bypass the focus-loss
                        // commit hook (the gate `visible &&` is false
                        // by then), losing the typed text — that was
                        // the original bug.
                        Keys.onEscapePressed: _commit()
                    }

                    // ---- Right-click menu ----
                    // Color swatches plus rename / delete. The
                    // canvas tool dock's '▢ Add group' button lives
                    // separately; this menu is for editing an
                    // existing group.
                    WfMenu {
                        id: groupMenu
                        WfMenuItem {
                            text: "Rename"
                            onTriggered: {
                                commentEditor.text = modelData.comment || ""
                                commentEditor.visible = true
                                commentEditor.forceActiveFocus()
                                commentEditor.selectAll()
                            }
                        }
                        MenuSeparator { }
                        WfMenuItem {
                            text: "● Amber"
                            onTriggered: root.editGroupColorRequested(groupItem.groupId, "accent")
                        }
                        WfMenuItem {
                            text: "● Green"
                            onTriggered: root.editGroupColorRequested(groupItem.groupId, "click")
                        }
                        WfMenuItem {
                            text: "● Blue"
                            onTriggered: root.editGroupColorRequested(groupItem.groupId, "type")
                        }
                        WfMenuItem {
                            text: "● Purple"
                            onTriggered: root.editGroupColorRequested(groupItem.groupId, "key")
                        }
                        WfMenuItem {
                            text: "● Pink"
                            onTriggered: root.editGroupColorRequested(groupItem.groupId, "notify")
                        }
                        WfMenuItem {
                            text: "● Orange"
                            onTriggered: root.editGroupColorRequested(groupItem.groupId, "shell")
                        }
                        WfMenuItem {
                            text: "● Neutral"
                            onTriggered: root.editGroupColorRequested(groupItem.groupId, "neutral")
                        }
                        MenuSeparator { }
                        WfMenuItem {
                            text: "Delete group"
                            destructive: true
                            onTriggered: root.deleteGroupRequested(groupItem.groupId)
                        }
                    }
                }
            }

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

            // Wire labels — small pills along the wire that carry a
            // label (currently "yes" / "no" on conditional branches).
            // Sibling Repeater so the labels paint above the strokes
            // without participating in the dash animation.
            Repeater {
                model: root._wirePairs
                delegate: Item {
                    visible: !!modelData.label
                        && fromPos !== undefined
                        && toPos !== undefined

                    readonly property int fromIdx: modelData.from
                    readonly property int toIdx: modelData.to
                    readonly property string fromId:
                        root.actions[fromIdx] ? root.actions[fromIdx].id : ""
                    readonly property string toId:
                        root.actions[toIdx] ? root.actions[toIdx].id : ""
                    readonly property var fromPos: root.positions[fromId]
                    readonly property var toPos: root.positions[toId]
                    readonly property real fromH:
                        root.cardHeights[fromId] || root.nodeMinH
                    readonly property real toH:
                        root.cardHeights[toId] || root.nodeMinH
                    readonly property real fromW: root.cardWidths[fromId]
                        || _widthForKind(root.actions[fromIdx]
                            ? root.actions[fromIdx].rawKind : "")
                    readonly property real toW: root.cardWidths[toId]
                        || _widthForKind(root.actions[toIdx]
                            ? root.actions[toIdx].rawKind : "")
                    readonly property var route:
                        _routeWire(fromPos, toPos, fromH, toH, fromW, toW)

                    // Plain coloured text floating above the wire
                    // midpoint — no pill. The subtle bg (a tinted
                    // rectangle a hair taller than the text) keeps
                    // the glyph readable against the dot grid
                    // without reading as a chip "sitting" on the
                    // wire.
                    Rectangle {
                        readonly property color labelColor: {
                            if (modelData.label === "yes") return Theme.ok
                            if (modelData.label === "no") return Theme.err
                            return Theme.text2
                        }
                        // Centre on midpoint, then lift 12px so the
                        // text reads as labelling the wire from
                        // above instead of being threaded onto it.
                        x: route.sx + (route.tx - route.sx) / 2 - width / 2
                        y: route.sy + (route.ty - route.sy) / 2 - height / 2 - 14
                        width: labelText.implicitWidth + 8
                        height: labelText.implicitHeight + 4
                        radius: 4
                        color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 0.85)
                        border.color: "transparent"
                        border.width: 0

                        Text {
                            id: labelText
                            anchors.centerIn: parent
                            text: modelData.label
                            color: parent.labelColor
                            font.family: Theme.familyBody
                            font.pixelSize: 11
                            font.weight: Font.Bold
                            font.letterSpacing: 0.5
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
                readonly property bool isSelected:
                    (root.selectedIndices && root.selectedIndices[model.index] === true)
                    || model.index === root.selectedIndex

                // Hover aggregation. The card-level dragArea
                // MouseArea loses containsMouse when the cursor moves
                // onto a child MouseArea (rewire / delete / note-del),
                // so any hover-revealed control gated on
                // dragArea.containsMouse alone vanishes the moment the
                // user tries to click it. Each child bumps this
                // counter on entry/exit; the gate becomes
                // `isHovered || isSelected` so the controls stay up
                // while the cursor is anywhere on the card.
                property int childHoverCount: 0
                readonly property bool isHovered:
                    dragArea.containsMouse || childHoverCount > 0
                readonly property var act: modelData
                readonly property string stepId: modelData ? modelData.id : ""
                readonly property string kind: modelData ? modelData.kind : "wait"
                readonly property string rawKind: modelData ? (modelData.rawKind || "") : ""
                // Container = a card that holds an inline inner-step
                // strip. Repeat is the only one now — conditionals
                // (when/unless) render as branch decision points
                // with their inner steps drawn as siblings on the
                // canvas, not nested inside.
                readonly property bool isContainer:
                    rawKind === "repeat"
                // Conditionals have their own visual shape: a leaf-
                // ish decision card with explicit yes/no output ports.
                readonly property bool isConditional:
                    rawKind === "conditional"
                // True when the engine is currently running this
                // step. Drives the pulsing accent border so the user
                // can see live which step is firing.
                readonly property bool isActive:
                    model.index === root.activeStepIndex
                    || model.index === root.activeParentIndex
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
                        : (cardItem.isConditional
                            ? Math.max(root.conditionalMinH, cardBody.implicitHeight + 24)
                            : Math.max(root.nodeMinH - 4, cardBody.implicitHeight + 24))
                    radius: cardItem.isNote ? 8 : 14
                    color: cardItem.cardBg
                    // Repeat containers + conditional decision cards
                    // carry a tinted border (their kind colour) so the
                    // structural / branch nodes read at a glance —
                    // ordinary action cards keep the neutral hairline.
                    // Notes get the softest border so they recede next
                    // to operations.
                    // Active-running indicator is the pulsing green
                    // status dot in the header — the card border stays
                    // its normal selection / kind colour so a flashing
                    // accent halo doesn't compete with selection.
                    border.color: cardItem.isSelected
                        ? Qt.rgba(0.55, 0.78, 0.88, 0.9)
                        : ((cardItem.isContainer || cardItem.isConditional)
                            ? Theme.catFor(cardItem.kind)
                            : (cardItem.isNote
                                ? Theme.lineSoft
                                : (dragArea.containsMouse ? Theme.line : Theme.lineSoft)))
                    border.width: cardItem.isSelected
                        ? 2
                        : ((cardItem.isContainer || cardItem.isConditional)
                            ? 1.5
                            : 1)

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
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
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
                        onPressed: (mouse) => {
                            _wasDragged = false
                            // Right-click pops the context menu but
                            // does NOT select the step — selection
                            // is the left-click affordance and slides
                            // the inspector in. The context menu
                            // operates on the card under the cursor
                            // regardless.
                            if (mouse.button === Qt.RightButton) {
                                cardContextMenu.popup()
                                mouse.accepted = true
                            }
                        }
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
                        onReleased: (mouse) => {
                            // Right-click already opened the context
                            // menu in onPressed. Don't also fire the
                            // selectStep behaviour below — that would
                            // slide the inspector in on every right-
                            // click.
                            if (mouse.button === Qt.RightButton) return
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
                                // Shift / ctrl click semantics match
                                // the rail: shift = range from anchor,
                                // ctrl/cmd = toggle individual.
                                const m = mouse.modifiers
                                if (m & Qt.ShiftModifier) {
                                    root.rangeSelectStep(model.index)
                                } else if (m & (Qt.ControlModifier | Qt.MetaModifier)) {
                                    root.toggleSelectStep(model.index)
                                } else {
                                    root.selectStep(model.index)
                                }
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
                                opacity: cardItem.isHovered || cardItem.isSelected ? 1 : 0
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
                                    onContainsMouseChanged: cardItem.childHoverCount =
                                        Math.max(0, cardItem.childHoverCount + (containsMouse ? 1 : -1))
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
                                width: 22; height: 22; radius: Theme.radiusSm
                                anchors.verticalCenter: parent.verticalCenter
                                color: rewireArea.containsMouse
                                    ? Theme.accent
                                    : Theme.surface3
                                border.color: rewireArea.containsMouse ? Theme.accent : Theme.lineSoft
                                border.width: 1
                                opacity: cardItem.isHovered || cardItem.isSelected ? 1 : 0
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
                                    onContainsMouseChanged: cardItem.childHoverCount =
                                        Math.max(0, cardItem.childHoverCount + (containsMouse ? 1 : -1))
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
                                // Active running step pulses green; on
                                // finish the dot stays in its terminal
                                // colour (ok / err / skipped). Note the
                                // running pulse fights the per-status
                                // colour Behavior — that's fine, the
                                // pulse opacity below masks it.
                                color: cardItem.isActive             ? Theme.ok
                                    :  cardItem.status === "ok"      ? Theme.ok
                                    :  cardItem.status === "error"   ? Theme.err
                                    :  cardItem.status === "skipped" ? Theme.text3
                                    :  Theme.lineSoft
                                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                                SequentialAnimation on opacity {
                                    running: cardItem.isActive && !Theme.reduceMotion
                                    loops: Animation.Infinite
                                    alwaysRunToEnd: false
                                    NumberAnimation { from: 1.0; to: 0.35; duration: 600; easing.type: Easing.InOutSine }
                                    NumberAnimation { from: 0.35; to: 1.0; duration: 600; easing.type: Easing.InOutSine }
                                }
                                // When the pulse animation stops the
                                // opacity Behavior settles us back to
                                // 1.0 cleanly. Without this binding
                                // restoration, the dot can be left at
                                // a mid-pulse value.
                                onIsActiveLikeChanged: if (!cardItem.isActive) opacity = 1.0
                                readonly property bool isActiveLike: cardItem.isActive

                                // Brief flash on status transitions so
                                // ok / error / skipped lands visibly
                                // mid-run instead of just snapping in.
                                onColorChanged: if (!cardItem.isActive && cardItem.status !== "") flashAnim.restart()
                                SequentialAnimation {
                                    id: flashAnim
                                    running: false
                                    NumberAnimation {
                                        target: statusDot
                                        property: "scale"
                                        from: 1.0
                                        to: 1.7
                                        duration: 140
                                        easing.type: Easing.OutQuad
                                    }
                                    NumberAnimation {
                                        target: statusDot
                                        property: "scale"
                                        from: 1.7
                                        to: 1.0
                                        duration: 220
                                        easing.type: Easing.InQuad
                                    }
                                }
                            }

                            // Quick-delete. Hover-revealed × pill at
                            // the right edge of the header row,
                            // mirroring the rewire button on the left.
                            // Click removes the step immediately —
                            // mirrors the rail's hover-controls × .
                            Rectangle {
                                id: deleteBtn
                                width: 22; height: 22; radius: Theme.radiusSm
                                anchors.verticalCenter: parent.verticalCenter
                                color: deleteArea.containsMouse
                                    ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.85)
                                    : Theme.surface3
                                border.color: deleteArea.containsMouse ? Theme.err : Theme.lineSoft
                                border.width: 1
                                opacity: cardItem.isHovered || cardItem.isSelected ? 1 : 0
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
                                    onContainsMouseChanged: cardItem.childHoverCount =
                                        Math.max(0, cardItem.childHoverCount + (containsMouse ? 1 : -1))
                                }
                            }
                        }

                        GradientPill {
                            kind: cardItem.kind
                            text: _pillText(cardItem.act)
                            icon: Theme.catGlyph(cardItem.kind)
                            width: parent.width
                        }

                        // Per-step comment, surfaced from the
                        // inspector's Comment field. Italic + smaller
                        // so it reads as an annotation under the
                        // step's primary value, not as another
                        // operation. Hidden when empty so cards
                        // without a note keep their compact height.
                        Text {
                            visible: cardItem.act
                                && cardItem.act.note
                                && cardItem.act.note.length > 0
                            text: cardItem.act ? (cardItem.act.note || "") : ""
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontXs
                            font.italic: true
                            wrapMode: Text.Wrap
                            width: parent.width
                            leftPadding: 2
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
                            // Min height: room for the Open button (6
                            // top + 28 height = 34) plus space for
                            // the empty-state placeholder centered
                            // below it. Once inner steps land, the
                            // strip drives the height.
                            height: visible
                                ? Math.max(108, innerStrip.implicitHeight + 50)
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
                                anchors.topMargin: 6
                                width: openLabel.implicitWidth + 24
                                height: 28
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
                                    font.pixelSize: 11
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
                            // 42px = 6 (innerZone topMargin) + 28
                            // (Open button height) + 8 (gap) — keeps
                            // the strip from overlapping the Open
                            // button at the top of the inner zone.
                            anchors.topMargin: 42
                            spacing: 3

                            // Notes are workflow annotations — they don't
                            // execute and shouldn't show up as inline
                            // rows in a repeat container. They still
                            // round-trip through KDL because
                            // cardItem.act.rawAction.steps is the raw
                            // backing array; we just filter the visual
                            // model here.
                            readonly property var inner: {
                                const ra = cardItem.act ? cardItem.act.rawAction : null
                                const all = (ra && ra.steps) ? ra.steps : []
                                const out = []
                                for (let i = 0; i < all.length; i++) {
                                    const s = all[i]
                                    if (s && s.action && s.action.kind === "note") continue
                                    out.push(s)
                                }
                                return out
                            }

                            Repeater {
                                model: innerStrip.inner
                                delegate: Rectangle {
                                    id: innerRow
                                    readonly property bool isInnerSelected:
                                        root.selectedIndex === cardItem.stepIdx
                                        && root.selectedInnerIndex === model.index
                                    readonly property string innerStepId:
                                        modelData ? (modelData.id || "") : ""
                                    readonly property bool innerIsActive:
                                        innerStepId.length > 0
                                        && root.activeStepId === innerStepId
                                    readonly property string innerStatus: {
                                        const m = root.stepStatusesById
                                        if (!m || !innerStepId) return ""
                                        const v = m[innerStepId]
                                        return v === undefined ? "" : v
                                    }
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
                                            // Subtract: num(14) + spacing(6) + icon(14)
                                            // + spacing(6) + dot(7) + spacing(6) + del(22)
                                            // + spacing(6).
                                            width: parent.width - 14 - 6 - 14 - 6 - 7 - 6 - 22 - 6
                                            text: _innerSummary(modelData)
                                            color: Theme.text2
                                            font.family: Theme.familyBody
                                            font.pixelSize: 10
                                            elide: Text.ElideRight
                                        }
                                        Rectangle {
                                            id: innerStatusDot
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 7; height: 7; radius: 3.5
                                            color: innerRow.innerIsActive          ? Theme.ok
                                                : innerRow.innerStatus === "ok"    ? Theme.ok
                                                : innerRow.innerStatus === "error" ? Theme.err
                                                : innerRow.innerStatus === "skipped" ? Theme.text3
                                                : Theme.lineSoft
                                            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                                            // Per-iteration flash. The bridge sets
                                            // active_step_id to the same inner-step id on
                                            // every iteration of a repeat, which dedupes at
                                            // the cxx-qt setter — QML never sees the
                                            // binding change. The unconditional `stepStarted`
                                            // signal lets us restart the pulse cleanly per
                                            // iteration so the user gets one visible pulse
                                            // per loop.
                                            SequentialAnimation {
                                                id: innerPulseAnim
                                                NumberAnimation { target: innerStatusDot; property: "opacity"; from: 1.0; to: 0.35; duration: 220; easing.type: Easing.OutSine }
                                                NumberAnimation { target: innerStatusDot; property: "opacity"; from: 0.35; to: 1.0; duration: 320; easing.type: Easing.InOutSine }
                                                NumberAnimation { target: innerStatusDot; property: "scale";   from: 1.0; to: 1.5; duration: 0 }
                                                NumberAnimation { target: innerStatusDot; property: "scale";   from: 1.5; to: 1.0; duration: 260; easing.type: Easing.InQuad }
                                            }
                                            Connections {
                                                target: root
                                                function onStepStarted(stepId) {
                                                    if (Theme.reduceMotion) return
                                                    if (!innerRow.innerStepId) return
                                                    if (stepId !== innerRow.innerStepId) return
                                                    innerPulseAnim.stop()
                                                    innerStatusDot.opacity = 1.0
                                                    innerStatusDot.scale = 1.0
                                                    innerPulseAnim.start()
                                                }
                                            }
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

                    // Right-click context menu for canvas cards.
                    // Mirrors the LibraryGrid card-menu: quick
                    // access to step-level actions without going
                    // through the inspector.
                    WfMenu {
                        id: cardContextMenu
                        WfMenuItem {
                            text: cardItem.act && cardItem.act.enabled === false
                                ? "Enable" : "Skip on run"
                            onTriggered: root.optionEdited(
                                cardItem.stepIdx, "enabled",
                                cardItem.act && cardItem.act.enabled === false)
                        }
                        WfMenuItem {
                            text: "Set predecessor / successor…"
                            onTriggered: rewireMenu.popup()
                        }
                        MenuSeparator {}
                        WfMenuItem {
                            text: "Delete"
                            onTriggered: root.deleteStepRequested(cardItem.stepIdx)
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

        // Port dots — small cyan circles at the wire endpoints so
        // each wire visibly attaches to its source / target card
        // instead of disappearing under the card edge. Sits at the
        // world level (sibling of nodeRep) with z higher than every
        // card so the dots paint over the card border. Dragging a
        // card sets that card's z to 100, so this layer also goes
        // to a number > 100 to stay visible during drag.
        Item {
            id: portLayer
            anchors.fill: parent
            z: 200
            Repeater {
                model: root._wirePairs
                delegate: Item {
                    readonly property int fromIdx: modelData.from
                    readonly property int toIdx: modelData.to
                    readonly property string fromId:
                        root.actions[fromIdx] ? root.actions[fromIdx].id : ""
                    readonly property string toId:
                        root.actions[toIdx] ? root.actions[toIdx].id : ""
                    readonly property var fromPos: root.positions[fromId]
                    readonly property var toPos: root.positions[toId]
                    readonly property real fromH:
                        root.cardHeights[fromId] || root.nodeMinH
                    readonly property real toH:
                        root.cardHeights[toId] || root.nodeMinH
                    readonly property real fromW: root.cardWidths[fromId]
                        || _widthForKind(root.actions[fromIdx]
                            ? root.actions[fromIdx].rawKind : "")
                    readonly property real toW: root.cardWidths[toId]
                        || _widthForKind(root.actions[toIdx]
                            ? root.actions[toIdx].rawKind : "")
                    readonly property var route:
                        _routeWire(fromPos, toPos, fromH, toH, fromW, toW)
                    visible: fromPos !== undefined && toPos !== undefined

                    // Port = a soft cyan halo behind a solid cyan
                    // dot with a small white-ish inner highlight,
                    // so the dot reads as a polished pill the wire
                    // plugs into rather than a flat sticker.
                    Item {
                        x: route.sx - root._portR
                        y: route.sy - root._portR
                        width: root._portR * 2
                        height: root._portR * 2

                        Rectangle {  // halo
                            anchors.centerIn: parent
                            width: parent.width + 6
                            height: parent.height + 6
                            radius: width / 2
                            color: Qt.rgba(0.55, 0.78, 0.88, 0.22)
                        }
                        Rectangle {  // body
                            anchors.fill: parent
                            radius: width / 2
                            color: Qt.rgba(0.55, 0.78, 0.88, 1.0)
                            border.color: Qt.rgba(0.32, 0.55, 0.70, 0.85)
                            border.width: 1
                            // Inner highlight — small offset white
                            // disc giving the impression of a top-
                            // left light source.
                            Rectangle {
                                x: parent.width * 0.18
                                y: parent.height * 0.18
                                width: parent.width * 0.42
                                height: parent.height * 0.42
                                radius: width / 2
                                color: Qt.rgba(1, 1, 1, 0.45)
                            }
                        }
                    }

                    Item {
                        x: route.tx - root._portR
                        y: route.ty - root._portR
                        width: root._portR * 2
                        height: root._portR * 2

                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width + 6
                            height: parent.height + 6
                            radius: width / 2
                            color: Qt.rgba(0.55, 0.78, 0.88, 0.22)
                        }
                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: Qt.rgba(0.55, 0.78, 0.88, 1.0)
                            border.color: Qt.rgba(0.32, 0.55, 0.70, 0.85)
                            border.width: 1
                            Rectangle {
                                x: parent.width * 0.18
                                y: parent.height * 0.18
                                width: parent.width * 0.42
                                height: parent.height * 0.42
                                radius: width / 2
                                color: Qt.rgba(1, 1, 1, 0.45)
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

    // ============ Empty-state hint ============
    // When no actions exist yet — the editor's first-impression
    // surface — show a centered prompt pointing at the palette.
    // Hidden the moment a step lands. The hint lives here (in the
    // canvas, not the page) so it stays correctly positioned even
    // when the inspector slides in or the breadcrumb appears.
    Rectangle {
        anchors.centerIn: parent
        visible: (root.actions || []).length === 0
        width: emptyCol.implicitWidth + 48
        height: emptyCol.implicitHeight + 32
        radius: Theme.radiusMd
        color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.92)
        border.color: Theme.lineSoft
        border.width: 1
        z: 50

        Column {
            id: emptyCol
            anchors.centerIn: parent
            spacing: 8

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "An empty workflow."
                color: Theme.text
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontMd
                font.weight: Font.DemiBold
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Drag a step from the palette on the left to get started."
                color: Theme.text3
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
            }
            Item { width: 1; height: 4 }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 6
                Text {
                    text: "←"
                    color: Theme.accent
                    font.family: Theme.familyBody
                    font.pixelSize: 14
                    font.weight: Font.Bold
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: "Type · Click · Shell · When · Repeat …"
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: Theme.fontXs
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    // ============ Floating UI ============

    // Vertical icon dock on the right edge of the canvas — Adobe /
    // Figma style. Stacks the three control groups (Tidy → Wires →
    // Zoom) as icon-only buttons separated by thin dividers; full
    // labels appear in tooltips on hover. Trades label legibility
    // for canvas real estate.
    readonly property int toolDockCollapsedW: 56
    readonly property int toolDockExpandedW: 200

    Rectangle {
        id: toolDock
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: 12
        // The child button MouseAreas with hoverEnabled grab the
        // QHoverEvent before HoverHandler sees it, so a single dock-
        // level hover detector misses the cursor when it sits on a
        // button. We aggregate instead: each button bumps
        // chipHoverCount, the HoverHandler covers the gaps + margin
        // ring around the dock.
        property int chipHoverCount: 0
        readonly property bool isHovered:
            toolDockHover.hovered || chipHoverCount > 0
        width: isHovered ? root.toolDockExpandedW : root.toolDockCollapsedW
        height: toolStack.implicitHeight + 16
        radius: Theme.radiusMd
        color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.94)
        border.color: Theme.lineSoft
        border.width: 1
        z: 60
        Behavior on width {
            NumberAnimation { duration: Theme.dur(Theme.durBase); easing.type: Easing.OutCubic }
        }

        HoverHandler {
            id: toolDockHover
            margin: 8
        }

        Component {
            id: toolBtnComp
            Rectangle {
                id: toolBtn
                property string glyph: ""
                property string tip: ""
                property string label: ""  // shown when dock expanded
                property bool active: false
                property var onActivate: null
                property real glyphSize: 18
                property bool useMono: false

                width: toolDock.width - 14
                height: 42
                anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
                radius: Theme.radiusSm
                readonly property bool expanded: toolDock.isHovered
                color: active
                    ? Theme.accentWash(0.18)
                    : (toolBtnArea.containsMouse ? Theme.surface2 : "transparent")
                border.color: active
                    ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
                    : "transparent"
                border.width: 1
                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                Text {
                    id: toolGlyph
                    x: 9
                    anchors.verticalCenter: parent.verticalCenter
                    text: toolBtn.glyph
                    color: toolBtn.active ? Theme.accent : Theme.text2
                    font.family: toolBtn.useMono ? Theme.familyMono : Theme.familyBody
                    font.pixelSize: toolBtn.glyphSize
                    font.weight: toolBtn.active ? Font.DemiBold : Font.Medium
                    width: 24
                    horizontalAlignment: Text.AlignHCenter
                }
                Text {
                    anchors.left: toolGlyph.right
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    visible: toolBtn.expanded && toolBtn.label !== ""
                    opacity: toolBtn.expanded ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durFast) } }
                    text: toolBtn.label
                    color: toolBtn.active ? Theme.accent : Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Medium
                }
                MouseArea {
                    id: toolBtnArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (toolBtn.onActivate) toolBtn.onActivate()
                    ToolTip.visible: containsMouse && !toolBtn.expanded
                    ToolTip.delay: 400
                    ToolTip.text: toolBtn.tip
                    onContainsMouseChanged: {
                        toolDock.chipHoverCount = Math.max(
                            0,
                            toolDock.chipHoverCount + (containsMouse ? 1 : -1))
                    }
                }
            }
        }

        // Thin divider between tool groups.
        Component {
            id: toolDivComp
            Item {
                width: toolDock.width - 14
                height: 7
                anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    height: 1
                    color: Theme.lineSoft
                }
            }
        }

        Column {
            id: toolStack
            anchors.centerIn: parent
            spacing: 2

            // ---- Group (annotation rectangle)
            Loader {
                sourceComponent: toolBtnComp
                onLoaded: {
                    item.glyph = "▢"
                    item.tip = "Add a group rectangle"
                    item.label = "Add group"
                    item.onActivate = () => root._addGroupAtViewportCenter()
                }
            }

            Loader { sourceComponent: toolDivComp }

            // ---- Tidy
            Loader {
                sourceComponent: toolBtnComp
                onLoaded: {
                    item.glyph = "≡"
                    item.tip = "Tidy as a vertical stack"
                    item.label = "Tidy vertical"
                    item.onActivate = () => organizeVertical()
                }
            }
            Loader {
                sourceComponent: toolBtnComp
                onLoaded: {
                    item.glyph = "⫼"
                    item.tip = "Tidy as a horizontal row"
                    item.label = "Tidy horizontal"
                    item.onActivate = () => organizeHorizontal()
                }
            }
            Loader {
                sourceComponent: toolBtnComp
                onLoaded: {
                    item.glyph = "▦"
                    item.tip = "Tidy as a wrapping grid"
                    item.label = "Tidy as grid"
                    item.onActivate = () => organizeGrid()
                }
            }

            Loader { sourceComponent: toolDivComp }

            // ---- Wires
            Rectangle {
                width: toolDock.width - 14
                height: 42
                anchors.horizontalCenter: parent.horizontalCenter
                radius: Theme.radiusSm
                readonly property bool isOn: root.wireStyle === "curve"
                readonly property bool expanded: toolDock.isHovered
                color: isOn
                    ? Theme.accentWash(0.18)
                    : (wsCurveArea.containsMouse ? Theme.surface2 : "transparent")
                border.color: isOn
                    ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
                    : "transparent"
                border.width: 1
                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                Text {
                    id: wsCurveGlyph
                    x: 9
                    anchors.verticalCenter: parent.verticalCenter
                    text: "⌒"
                    color: parent.isOn ? Theme.accent : Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: 18
                    font.weight: parent.isOn ? Font.DemiBold : Font.Medium
                    width: 24
                    horizontalAlignment: Text.AlignHCenter
                }
                Text {
                    anchors.left: wsCurveGlyph.right
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    visible: parent.expanded
                    opacity: parent.expanded ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durFast) } }
                    text: "Curved wires"
                    color: parent.parent.isOn ? Theme.accent : Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Medium
                }
                MouseArea {
                    id: wsCurveArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.wireStyle = "curve"
                    ToolTip.visible: containsMouse && !parent.expanded
                    ToolTip.delay: 400
                    ToolTip.text: "Curved (Bezier) wires"
                    onContainsMouseChanged: {
                        toolDock.chipHoverCount = Math.max(
                            0,
                            toolDock.chipHoverCount + (containsMouse ? 1 : -1))
                    }
                }
            }
            Rectangle {
                width: toolDock.width - 14
                height: 42
                anchors.horizontalCenter: parent.horizontalCenter
                radius: Theme.radiusSm
                readonly property bool isOn: root.wireStyle === "ortho"
                readonly property bool expanded: toolDock.isHovered
                color: isOn
                    ? Theme.accentWash(0.18)
                    : (wsOrthoArea.containsMouse ? Theme.surface2 : "transparent")
                border.color: isOn
                    ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45)
                    : "transparent"
                border.width: 1
                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                Text {
                    id: wsOrthoGlyph
                    x: 9
                    anchors.verticalCenter: parent.verticalCenter
                    text: "⌐"
                    color: parent.isOn ? Theme.accent : Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: 18
                    font.weight: parent.isOn ? Font.DemiBold : Font.Medium
                    width: 24
                    horizontalAlignment: Text.AlignHCenter
                }
                Text {
                    anchors.left: wsOrthoGlyph.right
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    visible: parent.expanded
                    opacity: parent.expanded ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durFast) } }
                    text: "Stepped wires"
                    color: parent.parent.isOn ? Theme.accent : Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Medium
                }
                MouseArea {
                    id: wsOrthoArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.wireStyle = "ortho"
                    ToolTip.visible: containsMouse && !parent.expanded
                    ToolTip.delay: 400
                    ToolTip.text: "Stepped (90°) wires"
                    onContainsMouseChanged: {
                        toolDock.chipHoverCount = Math.max(
                            0,
                            toolDock.chipHoverCount + (containsMouse ? 1 : -1))
                    }
                }
            }

            Loader { sourceComponent: toolDivComp }

            // ---- Zoom
            Loader {
                sourceComponent: toolBtnComp
                onLoaded: {
                    item.glyph = "+"
                    item.tip = "Zoom in"
                    item.label = "Zoom in"
                    item.glyphSize = 16
                    item.onActivate = () => root._zoomBy(0.1)
                }
            }
            Rectangle {
                width: toolDock.width - 14
                height: 26
                anchors.horizontalCenter: parent.horizontalCenter
                radius: Theme.radiusSm
                readonly property bool expanded: toolDock.isHovered
                color: zPctArea.containsMouse ? Theme.surface2 : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                Text {
                    id: zPctGlyph
                    x: 9
                    anchors.verticalCenter: parent.verticalCenter
                    text: Math.round(root.zoom * 100) + "%"
                    color: Theme.text2
                    font.family: Theme.familyMono
                    font.pixelSize: 12
                    width: 24
                    horizontalAlignment: Text.AlignHCenter
                }
                Text {
                    anchors.left: zPctGlyph.right
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    visible: parent.expanded
                    opacity: parent.expanded ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durFast) } }
                    text: "Reset zoom"
                    color: Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Medium
                }
                MouseArea {
                    id: zPctArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root._animateZoomTo(1.0, flick.contentX, flick.contentY)
                    ToolTip.visible: containsMouse && !parent.expanded
                    ToolTip.delay: 400
                    ToolTip.text: "Reset zoom to 100%"
                    onContainsMouseChanged: {
                        toolDock.chipHoverCount = Math.max(
                            0,
                            toolDock.chipHoverCount + (containsMouse ? 1 : -1))
                    }
                }
            }
            Loader {
                sourceComponent: toolBtnComp
                onLoaded: {
                    item.glyph = "−"
                    item.tip = "Zoom out"
                    item.label = "Zoom out"
                    item.glyphSize = 16
                    item.onActivate = () => root._zoomBy(-0.1)
                }
            }
            Loader {
                sourceComponent: toolBtnComp
                onLoaded: {
                    item.glyph = "⊡"
                    item.tip = "Fit all cards"
                    item.label = "Fit all"
                    item.onActivate = () => root._zoomToFit()
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
