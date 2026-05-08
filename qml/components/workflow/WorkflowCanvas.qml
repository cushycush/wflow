import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Shapes
import Wflow

// Free-positioning node editor. Cards live at absolute (x, y) and
// persist in `positions` keyed by step.id. Wires auto-route between
// consecutive steps in linear sequence; positions stay sticky except
// for the one-shot Organize buttons.
Item {
    id: root

    property var actions: []
    property int selectedIndex: 0
    property int selectedInnerIndex: -1
    // selectedIndices coexists with selectedIndex for back-compat.
    property var selectedIndices: ({})
    property int activeStepIndex: -1
    // activeParentIndex: actions-index of the parent conditional when
    // the active step is INNER, so the parent card pulses too.
    property int activeParentIndex: -1
    property var stepStatuses: ({})
    // Statuses keyed by stable step_id so inner steps inside a repeat
    // container (which don't surface as top-level cards) can find theirs.
    property var stepStatusesById: ({})
    property string activeStepId: ""
    property var groups: []

    // Marquee state in WORLD space (pre-zoom) so it lines up with each
    // card's x/y for hit-testing without further conversion.
    property bool _marqueeActive: false
    property real _marqueeStartX: 0
    property real _marqueeStartY: 0
    property real _marqueeCurrentX: 0
    property real _marqueeCurrentY: 0
    readonly property real _marqueeLeft:   Math.min(_marqueeStartX, _marqueeCurrentX)
    readonly property real _marqueeTop:    Math.min(_marqueeStartY, _marqueeCurrentY)
    readonly property real _marqueeRight:  Math.max(_marqueeStartX, _marqueeCurrentX)
    readonly property real _marqueeBottom: Math.max(_marqueeStartY, _marqueeCurrentY)
    // Live preview so cards light up as the rect crosses them, not on release.
    property var _marqueeHoverIndices: ({})

    // Committed selection ∪ live marquee preview. Siblings (left-rail
    // StepListRail) read this so their rows light up in lockstep with cards.
    readonly property var liveSelectedIndices: {
        if (!_marqueeActive) return selectedIndices
        const merged = {}
        for (const k in selectedIndices) merged[k] = true
        for (const k in _marqueeHoverIndices) merged[k] = true
        return merged
    }

    // scenePosition + world.mapFromItem in one shot dodges the ambiguity
    // about which Item handler.centroid.position is local to.
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
            _marqueeHoverIndices = ({})
            _marqueeActive = true
        } else {
            _marqueeActive = false
            _commitMarqueeSelection(
                _marqueeLeft, _marqueeTop, _marqueeRight, _marqueeBottom)
            _marqueeHoverIndices = ({})
        }
    }
    function _marqueeOnCentroidChanged(handler) {
        if (!handler.active) return
        const w = _handlerToWorld(handler)
        _marqueeCurrentX = w.x
        _marqueeCurrentY = w.y
        _marqueeHoverIndices = _indicesInMarqueeRect(
            _marqueeLeft, _marqueeTop, _marqueeRight, _marqueeBottom)
    }

    // Reactive stores. Cards write on drag-release and size-change; wires
    // and hit-tests read. Width is per-card so containers get correct
    // wire endpoints and drop bounds.
    property var positions: ({})    // { [id]: {x, y} }
    property var cardHeights: ({})  // { [id]: number }
    property var cardWidths: ({})   // { [id]: number }

    function _widthForKind(rawKind) {
        if (rawKind === "repeat") return containerW
        if (rawKind === "conditional") return conditionalW
        if (rawKind === "note") return noteW
        return nodeW
    }

    // Unknown names fall back to accent so a user-typed color in the KDL
    // file doesn't render as an invisible group.
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

    // Tiny drags are ignored as misclicks; threshold scales inversely
    // with zoom so a small on-screen wiggle doesn't fail at 200%.
    function _commitDrawGroup(wL, wT, wR, wB) {
        const minSpan = 24 / Math.max(0.01, root.zoom)
        if ((wR - wL) < minSpan || (wB - wT) < minSpan) return
        root.addGroupRequested(wL, wT, wR - wL, wB - wT)
    }

    function _addGroupAtViewportCenter() {
        const z = root.zoom > 0 ? root.zoom : 1
        const w = 320
        const h = 200
        const cx = (flick.contentX + flick.width  / 2) / z
        const cy = (flick.contentY + flick.height / 2) / z
        root.addGroupRequested(cx - w / 2, cy - h / 2, w, h)
    }

    function _indicesInMarqueeRect(wL, wT, wR, wB) {
        const out = ({})
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
                // Fresh card not yet in the position map.
                const card = nodeRep.itemAt(i)
                if (!card) continue
                cx = card.x; cy = card.y
            }
            if (cx + cw > wL && cx < wR && cy + ch > wT && cy < wB) {
                out[i] = true
            }
        }
        return out
    }

    function _commitMarqueeSelection(wL, wT, wR, wB) {
        const minSpan = 4 / Math.max(0.01, root.zoom)
        if ((wR - wL) < minSpan || (wB - wT) < minSpan) return
        const next = _indicesInMarqueeRect(wL, wT, wR, wB)
        if (Object.keys(next).length > 0) {
            root.marqueeSelected(next)
        }
    }

    // "curve" (Bezier) | "ortho" (90° segments).
    property string wireStyle: "curve"

    // Card positions stay in logical (unscaled) world coords; only the
    // world container carries the scale.
    property real zoom: 1.0
    readonly property real minZoom: 0.4
    readonly property real maxZoom: 1.6

    // Re-fires per step start so inner rows in a repeat container can
    // flash each iteration even when active_step_id stays unchanged.
    signal stepStarted(string stepId)

    signal selectStep(int index)
    signal rangeSelectStep(int index)
    signal toggleSelectStep(int index)
    signal marqueeSelected(var indicesSet)
    signal deselectRequested()

    signal addGroupRequested(real x, real y, real width, real height)
    signal moveGroupRequested(string id, real x, real y)
    signal resizeGroupRequested(string id, real x, real y, real width, real height)
    signal deleteGroupRequested(string id)
    signal editGroupCommentRequested(string id, string comment)
    signal editGroupColorRequested(string id, string color)
    signal addStepAtRequested(string kind, real x, real y)
    signal deleteStepRequested(int index)
    signal addInnerStepRequested(int stepIndex, string kind)
    signal deleteInnerStepRequested(int stepIndex, int innerIndex)
    signal moveStepToContainerRequested(int fromIndex, int containerIndex)
    signal selectInnerStep(int parentIndex, int innerIndex)
    signal openContainerRequested(int stepIndex)
    signal openUseRequested(int stepIndex)
    signal optionEdited(int stepIndex, string path, var value)
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

    // Wire endpoints. Notes are skipped; wires bridge directly between
    // operational steps.
    readonly property var _wirePairs: {
        const arr = root.actions || []
        const out = []

        // "" / "yes" / undefined all count as the yes branch.
        function _matchesSide(it, wantSide) {
            const s = it._branchSide || ""
            if (wantSide === "no") return s === "no"
            return s !== "no"
        }

        function firstInnerOf(parentTopIdx, wantSide) {
            let best = -1
            let bestJ = Number.MAX_SAFE_INTEGER
            for (let i = 0; i < arr.length; i++) {
                const it = arr[i]
                if (!it) continue
                if (it._displayKind === "inner"
                    && it._parentTopIdx === parentTopIdx
                    && it.rawKind !== "note"
                    && _matchesSide(it, wantSide)
                    && it._innerIdx < bestJ) {
                    best = i
                    bestJ = it._innerIdx
                }
            }
            return best
        }

        function lastInnerOf(parentTopIdx, wantSide) {
            let best = -1
            let bestJ = -1
            for (let i = 0; i < arr.length; i++) {
                const it = arr[i]
                if (!it) continue
                if (it._displayKind === "inner"
                    && it._parentTopIdx === parentTopIdx
                    && it.rawKind !== "note"
                    && _matchesSide(it, wantSide)
                    && it._innerIdx > bestJ) {
                    best = i
                    bestJ = it._innerIdx
                }
            }
            return best
        }

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
                    const firstYes = firstInnerOf(it._topIdx, "yes")
                    const lastYes  = lastInnerOf(it._topIdx, "yes")
                    const firstNo  = firstInnerOf(it._topIdx, "no")
                    const lastNo   = lastInnerOf(it._topIdx, "no")
                    const nextTop  = nextTopAfter(it._topIdx)

                    if (firstYes >= 0) {
                        out.push({ from: i, to: firstYes, label: "yes" })
                    }
                    if (firstNo >= 0) {
                        out.push({ from: i, to: firstNo, label: "no" })
                    }
                    if (nextTop >= 0) {
                        // Direct cond → next-top only when an empty
                        // branch would otherwise leave the main flow
                        // disconnected.
                        if (firstYes < 0 && firstNo < 0) {
                            out.push({ from: i, to: nextTop })
                        } else if (firstYes < 0) {
                            out.push({ from: i, to: nextTop, label: "yes" })
                        } else if (firstNo < 0) {
                            out.push({ from: i, to: nextTop, label: "no" })
                        }
                    }
                    if (lastYes >= 0 && nextTop >= 0) {
                        out.push({ from: lastYes, to: nextTop })
                    }
                    if (lastNo >= 0 && nextTop >= 0) {
                        out.push({ from: lastNo, to: nextTop })
                    }
                } else {
                    const nextTop = nextTopAfter(it._topIdx)
                    if (nextTop >= 0) out.push({ from: i, to: nextTop })
                }
            } else if (it._displayKind === "inner") {
                const mySide = it._branchSide || ""
                let bestJ = Number.MAX_SAFE_INTEGER
                let bestK = -1
                for (let j = 0; j < arr.length; j++) {
                    const next = arr[j]
                    if (!next) continue
                    if (next._displayKind !== "inner") continue
                    if (next._parentTopIdx !== it._parentTopIdx) continue
                    if (next.rawKind === "note") continue
                    const nextSide = next._branchSide || ""
                    // Unsided ("") chains as yes so repeat-container inners work.
                    const sameSide = (mySide === "no") === (nextSide === "no")
                    if (!sameSide) continue
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
    // canvasOrigin centres spawn inside the 12k canvas span so pan-left
    // doesn't dead-end at contentX = 0.
    readonly property int canvasOrigin: canvasSpan / 2
    readonly property int paddingLeft: canvasOrigin - 200
    readonly property int paddingTop: canvasOrigin - 120
    readonly property int paddingBottom: 60

    // Yes-side first, no-side second, sorted by inner index within each.
    function _innerOf(list, parentTopIdx) {
        return list.filter(it => it && it._displayKind === "inner"
            && it._parentTopIdx === parentTopIdx)
            .sort((a, b) => {
                const aNo = (a._branchSide || "") === "no"
                const bNo = (b._branchSide || "") === "no"
                if (aNo !== bNo) return aNo ? 1 : -1
                return a._innerIdx - b._innerIdx
            })
    }

    // side is "yes" (default / repeat) or "no" (conditional else).
    // Untagged inners count as yes.
    function _innerOfBranch(list, parentTopIdx, side) {
        return list.filter(it => {
            if (!it || it._displayKind !== "inner") return false
            if (it._parentTopIdx !== parentTopIdx) return false
            const s = it._branchSide || ""
            return side === "no" ? s === "no" : s !== "no"
        }).sort((a, b) => a._innerIdx - b._innerIdx)
    }

    function organizeVertical() {
        // Main flow down centre column. Conditionals fan out: yes-side
        // RIGHT, no-side LEFT. Both branch columns start at the
        // conditional's vertical midpoint.
        const list = root.actions || []
        const tops = list.filter(it => it && it._displayKind === "top")
        if (tops.length === 0) return

        let maxTopW = nodeW
        for (const t of tops) {
            const w = cardWidths[t.id] || _widthForKind(t.rawKind)
            if (w > maxTopW) maxTopW = w
        }
        const centerX = paddingLeft + maxTopW / 2 + nodeW
        const topRightEdge = centerX + maxTopW / 2
        const topLeftEdge  = centerX - maxTopW / 2
        const yesColLeft   = topRightEdge + gap * 2
        const noColRight   = topLeftEdge  - gap * 2

        // colX is a function so the no-column can flip its anchor
        // based on each card's width (right-edge fixed, extend left).
        function placeColumn(inner, branchTopY, colX) {
            let yCur = branchTopY
            let span = 0
            for (let k = 0; k < inner.length; k++) {
                const ic = inner[k]
                const iw = cardWidths[ic.id] || _widthForKind(ic.rawKind)
                const ih = cardHeights[ic.id] || nodeMinH
                next[ic.id] = { x: colX(iw), y: yCur }
                yCur += ih
                span += ih
                if (k < inner.length - 1) {
                    yCur += gap
                    span += gap
                }
            }
            return span
        }

        const next = {}
        let y = paddingTop
        for (let i = 0; i < tops.length; i++) {
            const it = tops[i]
            const w = cardWidths[it.id] || _widthForKind(it.rawKind)
            const h = cardHeights[it.id] || nodeMinH
            next[it.id] = { x: centerX - w / 2, y: y }

            let nextY = y + h + gap

            if (it.rawKind === "conditional") {
                const yesInner = _innerOfBranch(list, it._topIdx, "yes")
                    .filter(ic => ic.rawKind !== "note")
                const noInner  = _innerOfBranch(list, it._topIdx, "no")
                    .filter(ic => ic.rawKind !== "note")
                if (yesInner.length > 0 || noInner.length > 0) {
                    const branchTopY = y + h / 2
                    const yesSpan = yesInner.length
                        ? placeColumn(yesInner, branchTopY, () => yesColLeft)
                        : 0
                    const noSpan = noInner.length
                        ? placeColumn(noInner, branchTopY,
                              (iw) => noColRight - iw)
                        : 0
                    // nextH is an estimate; the next top isn't laid
                    // out yet, so we approximate from the current top.
                    const longestSpan = Math.max(yesSpan, noSpan)
                    const branchEndY = branchTopY + longestSpan
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
        // Main flow L→R along a centre row. Yes branches drop BELOW
        // the parent, no branches go ABOVE.
        const list = root.actions || []
        const tops = list.filter(it => it && it._displayKind === "top")
        if (tops.length === 0) return

        let maxTopH = nodeMinH
        for (const t of tops) {
            const h = cardHeights[t.id] || nodeMinH
            if (h > maxTopH) maxTopH = h
        }
        let maxBranchH = nodeMinH
        for (const t of tops) {
            if (t.rawKind !== "conditional") continue
            const inner = _innerOf(list, t._topIdx)
                .filter(ic => ic.rawKind !== "note")
            for (const ic of inner) {
                const ih = cardHeights[ic.id] || nodeMinH
                if (ih > maxBranchH) maxBranchH = ih
            }
        }
        // Position the main row so that:
        //   - the no-row above has gap*2 clearance from the canvas top
        //     AND gap*2 clearance from the conditional's top edge, and
        //   - the yes-row below has gap*2 clearance from the
        //     conditional's bottom edge.
        // Adding maxBranchH/2 to each row centre lifts/drops the row
        // by half a branch-card so the EDGE clearance lands at gap*2.
        const centerY = paddingTop + maxBranchH + gap * 2 + maxTopH / 2
        const yesRowY = centerY + maxTopH / 2 + gap * 2 + maxBranchH / 2
        const noRowY  = centerY - maxTopH / 2 - gap * 2 - maxBranchH / 2

        function placeRow(inner, branchStartX, rowCentreY) {
            let xCur = branchStartX
            let span = 0
            for (let k = 0; k < inner.length; k++) {
                const ic = inner[k]
                const iw = cardWidths[ic.id] || _widthForKind(ic.rawKind)
                const ih = cardHeights[ic.id] || nodeMinH
                next[ic.id] = { x: xCur, y: rowCentreY - ih / 2 }
                xCur += iw
                span += iw
                if (k < inner.length - 1) {
                    xCur += gap
                    span += gap
                }
            }
            return span
        }

        const next = {}
        let x = paddingLeft
        for (let i = 0; i < tops.length; i++) {
            const it = tops[i]
            const w = cardWidths[it.id] || _widthForKind(it.rawKind)
            const h = cardHeights[it.id] || nodeMinH
            next[it.id] = { x: x, y: centerY - h / 2 }

            let nextX = x + w + gap

            if (it.rawKind === "conditional") {
                const yesInner = _innerOfBranch(list, it._topIdx, "yes")
                    .filter(ic => ic.rawKind !== "note")
                const noInner  = _innerOfBranch(list, it._topIdx, "no")
                    .filter(ic => ic.rawKind !== "note")
                if (yesInner.length > 0 || noInner.length > 0) {
                    const branchStartX = x + w + gap * 2
                    const yesSpan = yesInner.length
                        ? placeRow(yesInner, branchStartX, yesRowY)
                        : 0
                    const noSpan = noInner.length
                        ? placeRow(noInner, branchStartX, noRowY)
                        : 0
                    const longestSpan = Math.max(yesSpan, noSpan)
                    const branchEndX = branchStartX + longestSpan
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
        // Square-ish grid. Conditional branches split inside each cell:
        // no-side stacks ABOVE the parent, yes-side BELOW.
        // INVARIANT: every parent in a row shares one baseline Y so
        // inter-cell main-flow wires run cleanly along it, not threading
        // through any branch stack.
        const list = root.actions || []
        if (list.length === 0) return
        const tops = list.filter(it => it && it._displayKind === "top")
        if (tops.length === 0) return

        const cols = Math.max(1, Math.ceil(Math.sqrt(tops.length)))

        function stackHeight(inner) {
            if (inner.length === 0) return 0
            let span = 0
            for (let k = 0; k < inner.length; k++) {
                span += cardHeights[inner[k].id] || nodeMinH
                if (k < inner.length - 1) span += gap
            }
            return span
        }

        // Per-row metrics: above (max no-stack), parent (tallest top),
        // below (max yes-stack). Baseline = top + above + parent / 2.
        const colWidths = []
        const rowAbove  = []
        const rowParent = []
        const rowBelow  = []
        for (let i = 0; i < tops.length; i++) {
            const a = tops[i]
            const col = i % cols
            const row = Math.floor(i / cols)
            let cellW = cardWidths[a.id] || _widthForKind(a.rawKind)
            const ph = cardHeights[a.id] || nodeMinH
            let above = 0, below = 0
            if (a.rawKind === "conditional") {
                const yesInner = _innerOfBranch(list, a._topIdx, "yes")
                    .filter(ic => ic.rawKind !== "note")
                const noInner = _innerOfBranch(list, a._topIdx, "no")
                    .filter(ic => ic.rawKind !== "note")
                const yesH = stackHeight(yesInner)
                const noH  = stackHeight(noInner)
                if (noH  > 0) above = noH + gap
                if (yesH > 0) below = yesH + gap
                for (const ic of yesInner) {
                    const iw = cardWidths[ic.id] || _widthForKind(ic.rawKind)
                    if (iw > cellW) cellW = iw
                }
                for (const ic of noInner) {
                    const iw = cardWidths[ic.id] || _widthForKind(ic.rawKind)
                    if (iw > cellW) cellW = iw
                }
            }
            colWidths[col] = Math.max(colWidths[col] || 0, cellW)
            rowAbove[row]  = Math.max(rowAbove[row]  || 0, above)
            rowParent[row] = Math.max(rowParent[row] || 0, ph)
            rowBelow[row]  = Math.max(rowBelow[row]  || 0, below)
        }

        const colX = [paddingLeft]
        for (let c = 1; c < cols; c++) {
            colX.push(colX[c - 1] + colWidths[c - 1] + gap * 2)
        }
        const rowBaseline = []
        let yCursor = paddingTop
        for (let r = 0; r < rowAbove.length; r++) {
            const top    = rowAbove[r]
            const parent = rowParent[r]
            const below  = rowBelow[r]
            rowBaseline[r] = yCursor + top + parent / 2
            yCursor += top + parent + below + gap * 2
        }

        const next = {}
        for (let i = 0; i < tops.length; i++) {
            const a = tops[i]
            const col = i % cols
            const row = Math.floor(i / cols)
            const w = cardWidths[a.id] || _widthForKind(a.rawKind)
            const h = cardHeights[a.id] || nodeMinH
            const centreX = colX[col] + colWidths[col] / 2
            const baseline = rowBaseline[row]

            const parentY = baseline - h / 2
            next[a.id] = { x: centreX - w / 2, y: parentY }

            if (a.rawKind === "conditional") {
                const yesInner = _innerOfBranch(list, a._topIdx, "yes")
                    .filter(ic => ic.rawKind !== "note")
                const noInner = _innerOfBranch(list, a._topIdx, "no")
                    .filter(ic => ic.rawKind !== "note")

                // No-stack grows upward from above the parent.
                let yBot = parentY - gap
                for (let k = noInner.length - 1; k >= 0; k--) {
                    const ic = noInner[k]
                    const iw = cardWidths[ic.id] || _widthForKind(ic.rawKind)
                    const ih = cardHeights[ic.id] || nodeMinH
                    next[ic.id] = { x: centreX - iw / 2, y: yBot - ih }
                    yBot = yBot - ih - gap
                }

                // Yes-stack grows downward from below the parent.
                let yTop = parentY + h + gap
                for (const ic of yesInner) {
                    const iw = cardWidths[ic.id] || _widthForKind(ic.rawKind)
                    const ih = cardHeights[ic.id] || nodeMinH
                    next[ic.id] = { x: centreX - iw / 2, y: yTop }
                    yTop += ih + gap
                }
            }
        }
        positions = next
        Qt.callLater(_zoomToFit)
    }

    // Reading-order tidy. Picks the fewest columns that hit a readable
    // zoom (~0.8); falls back to whichever zooms best if none clear that
    // bar. Branches stay glued to their parent across column wraps.
    function organizeSmart() {
        const list = root.actions || []
        const tops = list.filter(it => it && it._displayKind === "top")
        if (tops.length === 0) return
        if (flick.width <= 0 || flick.height <= 0) return

        // Per-top cell footprint. Conditionals split branches around
        // the parent: yes column RIGHT, no column LEFT, both stacking
        // down from the parent's vertical mid.
        const cells = tops.map(t => {
            const w = cardWidths[t.id] || _widthForKind(t.rawKind)
            const h = cardHeights[t.id] || nodeMinH
            if (t.rawKind !== "conditional") {
                return {
                    top: t, w, h,
                    yesInner: [], noInner: [],
                    yesColW: 0, yesColH: 0,
                    noColW: 0, noColH: 0
                }
            }
            const yesInner = _innerOfBranch(list, t._topIdx, "yes")
                .filter(ic => ic.rawKind !== "note")
            const noInner = _innerOfBranch(list, t._topIdx, "no")
                .filter(ic => ic.rawKind !== "note")
            let yesColW = 0, yesColH = 0
            for (let k = 0; k < yesInner.length; k++) {
                const iw = cardWidths[yesInner[k].id] || _widthForKind(yesInner[k].rawKind)
                const ih = cardHeights[yesInner[k].id] || nodeMinH
                if (iw > yesColW) yesColW = iw
                yesColH += ih
                if (k < yesInner.length - 1) yesColH += gap
            }
            let noColW = 0, noColH = 0
            for (let k = 0; k < noInner.length; k++) {
                const iw = cardWidths[noInner[k].id] || _widthForKind(noInner[k].rawKind)
                const ih = cardHeights[noInner[k].id] || nodeMinH
                if (iw > noColW) noColW = iw
                noColH += ih
                if (k < noInner.length - 1) noColH += gap
            }
            return {
                top: t, w, h,
                yesInner, noInner,
                yesColW, yesColH,
                noColW, noColH
            }
        })

        const padding = 60

        function cellHeight(cell) {
            const branchExtent = cell.h / 2 + Math.max(cell.yesColH, cell.noColH)
            return Math.max(cell.h, branchExtent)
        }

        // Pre-compute leftPad per column so every cell's parent lands
        // at the same X, keeping inter-cell wires on one vertical line.
        function simulate(cols) {
            const perCol = Math.ceil(cells.length / cols)
            const colW = new Array(cols).fill(0)
            const colH = new Array(cols).fill(0)
            const colLeftPad = new Array(cols).fill(0)
            for (let c = 0; c < cols; c++) {
                const start = c * perCol
                const end = Math.min(start + perCol, cells.length)
                let maxNoColW = 0
                for (let i = start; i < end; i++) {
                    if (cells[i].noColW > maxNoColW) maxNoColW = cells[i].noColW
                }
                const lp = maxNoColW > 0 ? maxNoColW + gap * 2 : 0
                colLeftPad[c] = lp
                for (let i = start; i < end; i++) {
                    const cell = cells[i]
                    const totalW = lp + cell.w +
                        (cell.yesColW > 0 ? gap * 2 + cell.yesColW : 0)
                    if (totalW > colW[c]) colW[c] = totalW
                    colH[c] += cellHeight(cell)
                    if (i < end - 1) colH[c] += gap
                }
            }
            const totalW = colW.reduce((a, b) => a + b, 0)
                + Math.max(0, cols - 1) * gap * 2
            const maxH = Math.max(...colH, 0)
            return { perCol, colW, colH, colLeftPad, totalW, maxH }
        }

        // Below this, 13/14px body text starts hurting at 1280×800.
        const READABLE_ZOOM = 0.78
        // Past 3 the eye loses the reading rhythm.
        const MAX_COLS = Math.min(cells.length, 3)

        function fitZoom(sim) {
            const fitW = sim.totalW + padding * 2
            const fitH = sim.maxH + padding * 2
            return Math.min(
                Math.min(flick.width / fitW, flick.height / fitH),
                1.0)
        }

        // First col-count that hits READABLE_ZOOM wins; otherwise pick
        // whichever zooms highest.
        let pick = null
        let fallback = null
        for (let cols = 1; cols <= MAX_COLS; cols++) {
            const sim = simulate(cols)
            const z = fitZoom(sim)
            if (!fallback || z > fallback.z) fallback = { cols, z, sim }
            if (z >= READABLE_ZOOM) {
                pick = { cols, z, sim }
                break
            }
        }
        if (!pick) pick = fallback
        if (!pick) return

        const sim = pick.sim
        const next = {}
        let xCursor = paddingLeft
        for (let c = 0; c < pick.cols; c++) {
            let yCursor = paddingTop
            const lp = sim.colLeftPad[c]
            const start = c * sim.perCol
            const end = Math.min(start + sim.perCol, cells.length)
            for (let i = start; i < end; i++) {
                const cell = cells[i]
                const ppX = xCursor + lp
                next[cell.top.id] = { x: ppX, y: yCursor }
                if (cell.yesInner.length > 0) {
                    const branchX = ppX + cell.w + gap * 2
                    let branchY = yCursor + cell.h / 2
                    for (let k = 0; k < cell.yesInner.length; k++) {
                        const ic = cell.yesInner[k]
                        const ih = cardHeights[ic.id] || nodeMinH
                        next[ic.id] = { x: branchX, y: branchY }
                        branchY += ih + gap
                    }
                }
                if (cell.noInner.length > 0) {
                    let branchY = yCursor + cell.h / 2
                    for (let k = 0; k < cell.noInner.length; k++) {
                        const ic = cell.noInner[k]
                        const iw = cardWidths[ic.id] || _widthForKind(ic.rawKind)
                        const ih = cardHeights[ic.id] || nodeMinH
                        // Right-align so wider cards extend leftward.
                        next[ic.id] = { x: ppX - gap * 2 - iw, y: branchY }
                        branchY += ih + gap
                    }
                }
                yCursor += cellHeight(cell) + gap
            }
            xCursor += sim.colW[c] + gap * 2
        }
        positions = next
        Qt.callLater(_zoomToFit)
    }

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

    // Cursor-anchored zoom: world coord under the cursor stays put.
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

    // Snaps to the nearest 10% step so +/- clicks land at clean
    // 60% / 70% / … regardless of where wheel zoom left things.
    function _zoomBy(delta) {
        const cur = Math.round(zoom * 10) / 10
        _zoomAt(Qt.point(flick.width / 2, flick.height / 2), cur + delta)
    }

    function _animateZoomTo(newZoom, newCX, newCY) {
        zoom = newZoom
        flick.contentX = newCX
        flick.contentY = newCY
    }

    Behavior on zoom {
        enabled: !Theme.reduceMotion
        NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Theme.easingStd }
    }

    property bool _firstLoadDone: false

    // Defers via timer because cards publish height/width via
    // onHeightChanged AFTER render, later than Qt.callLater can wait for.
    Timer {
        id: firstLoadFitTimer
        interval: 120
        repeat: false
        onTriggered: root._zoomToFit()
    }
    property real _firstLoadTs: 0
    Connections {
        target: root
        function onCardHeightsChanged() {
            if (!root._firstLoadDone) return
            if (Date.now() - root._firstLoadTs > 500) return
            firstLoadFitTimer.restart()
        }
    }

    // Stack newly-added cards under the existing layout; existing
    // positions stay put. Auto-fits viewport once on first load.
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
            const item = list[i]
            if (next[item.id]) continue
            if (item._displayKind === "inner") {
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
        }
        if (!_firstLoadDone && Object.keys(next).length > 0) {
            _firstLoadDone = true
            _firstLoadTs = Date.now()
            firstLoadFitTimer.restart()
        }
    }
    onActionsChanged: _placeNewSteps()
    Component.onCompleted: _placeNewSteps()

    // Drag preview state. The palette drives these directly; we draw a
    // card-shaped ghost in canvas-local coords instead of a system cursor.
    property string ghostKind: ""
    property real ghostX: 0
    property real ghostY: 0
    readonly property bool ghostActive: ghostKind.length > 0
    property int hoveredContainerIndex: -1

    // Top-level only; nested containers aren't drop targets yet.
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
            const w = world.mapFromItem(null, sceneX, sceneY)
            const containerIdx = _containerAt(w.x, w.y)
            if (containerIdx >= 0) {
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

    // Fixed-but-large span so Flickable doesn't clamp pan to the card
    // bounding box. Unscaled; Flickable.contentWidth multiplies by zoom.
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

    // Behind the Flickable so dots stay anchored to the viewport.
    // DotGrid paints its own Theme.bg fill.
    DotGrid {
        anchors.fill: parent
        z: -1
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: root.contentW * root.zoom
        contentHeight: root.contentH * root.zoom
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // Explicit DragHandler below owns pan; Flickable's built-in
        // drag fights TapHandler and card MouseAreas.
        interactive: false

        // Animate together with zoom so the cursor anchor stays correct
        // mid-zoom. Disabled during pan so drag-pan stays instant.
        Behavior on contentX {
            enabled: !Theme.reduceMotion && !panHandler.active
            NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Theme.easingStd }
        }
        Behavior on contentY {
            enabled: !Theme.reduceMotion && !panHandler.active
            NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Theme.easingStd }
        }

        // Wheel-only: NoButton + hoverEnabled false so cards underneath
        // still get hover events; wheel still delivers (hit-tested
        // independently of hover).
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

        // Bare drag = pan. Shift / Ctrl / Alt are claimed by the
        // marquee + draw-group handlers below.
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

        // Shift OR Ctrl + drag = marquee. acceptedModifiers is an exact
        // match (not flags-OR) so each modifier needs its own handler;
        // both share state via root-level marquee* properties.
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

        // Alt+drag = new group rectangle. WORLD coords throughout so
        // the on-screen rect and the commit hit-test agree.
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

        TapHandler {
            onTapped: root.deselectRequested()
        }

        // Wires + cards in unscaled coords. scale on the world Item
        // applies zoom to everything inside in one shot.
        Item {
            id: world
            width: root.contentW
            height: root.contentH
            transformOrigin: Item.TopLeft
            scale: root.zoom

            // Drawn inside `world` so they stay glued to cards under
            // pan/zoom; border widths scale inversely so the stroke
            // stays ~1px on-screen regardless of zoom.
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

            // Decorative group rectangles. Engine ignores them.
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

                    // preventStealing keeps the canvas pan handler from
                    // taking over mid-drag.
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

                    // DragHandler.translation is in stable coords, so
                    // resize avoids the mouse.x feedback-loop bug.
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

                    // No MouseArea over the label so the body's drag
                    // isn't blocked when clicking through.
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

                    // TextEdit (not TextInput) so Enter inserts a newline;
                    // commit on Esc or focus-loss.
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
                        // Hiding before _commit would bypass the
                        // focus-loss hook and drop the typed text.
                        Keys.onEscapePressed: _commit()
                    }

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
                    readonly property var route: _routeWire(fromPos, toPos, fromH, toH, fromW, toW, toId)

                    visible: fromPos !== undefined && toPos !== undefined
                    anchors.fill: parent
                    smooth: true
                    // No layer.enabled — marching dashes re-rasterise
                    // every frame, so an offscreen cache doubles work.

                    // Pattern total = 4 + 8 = 12; dashOffset 0 → -12
                    // over 1200ms gives one cycle/sec. Negative offset
                    // so the flow agrees with the path direction.
                    ShapePath {
                        strokeColor: Theme.lineStrong
                        strokeWidth: 1.6
                        fillColor: "transparent"
                        strokeStyle: Theme.reduceMotion ? ShapePath.SolidLine : ShapePath.DashLine
                        dashPattern: [4, 8]

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

            // Wire labels, small pills along the wire that carry a
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
                        _routeWire(fromPos, toPos, fromH, toH, fromW, toW, toId)

                    Rectangle {
                        readonly property color labelColor: {
                            if (modelData.label === "yes") return Theme.ok
                            if (modelData.label === "no") return Theme.err
                            return Theme.text2
                        }
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

        Repeater {
            id: nodeRep
            model: root.actions

            delegate: Item {
                id: cardItem
                width: _widthForKind(rawKind)
                height: card.height
                z: dragArea.drag.active ? 100 : 2

                // Stable index so inner Repeaters can't shadow it.
                readonly property int stepIdx: model.index
                readonly property bool _marqueeHovered:
                    root._marqueeActive
                    && root._marqueeHoverIndices
                    && root._marqueeHoverIndices[model.index] === true
                readonly property bool isSelected:
                    (root.selectedIndices && root.selectedIndices[model.index] === true)
                    || model.index === root.selectedIndex
                    || _marqueeHovered

                // dragArea.containsMouse drops when a child MouseArea
                // takes over; child hovers bump this so reveal
                // controls don't disappear under the cursor.
                property int childHoverCount: 0
                readonly property bool isHovered:
                    dragArea.containsMouse || childHoverCount > 0
                readonly property var act: modelData
                readonly property string stepId: modelData ? modelData.id : ""
                readonly property string kind: modelData ? modelData.kind : "wait"
                readonly property string rawKind: modelData ? (modelData.rawKind || "") : ""
                readonly property bool isContainer:
                    rawKind === "repeat"
                readonly property bool isConditional:
                    rawKind === "conditional"
                readonly property bool isActive:
                    model.index === root.activeStepIndex
                    || model.index === root.activeParentIndex
                readonly property bool isNote: rawKind === "note"
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

                // Suppress position Behaviors on first sync so fresh
                // delegates don't animate from (0,0) to saved coords.
                property bool _settled: false

                function _syncFromPositions() {
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
                    border.color: cardItem.isSelected
                        ? Theme.accent
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

                    MouseArea {
                        id: dragArea
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        cursorShape: dragArea.drag.active ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                        // Otherwise the canvas pan handler steals card
                        // drags past the motion threshold.
                        preventStealing: true
                        drag.target: cardItem
                        drag.axis: Drag.XAndYAxis
                        drag.threshold: 4
                        property bool _wasDragged: false
                        onPressed: (mouse) => {
                            _wasDragged = false
                            // Right-click only pops the menu; left-click
                            // selects (and slides the inspector in).
                            if (mouse.button === Qt.RightButton) {
                                cardContextMenu.popup()
                                mouse.accepted = true
                            }
                        }
                        // Write per drag-step (not just on release) so
                        // wires track live.
                        onPositionChanged: {
                            if (drag.active) {
                                _wasDragged = true
                                const next = Object.assign({}, root.positions)
                                next[cardItem.stepId] = { x: cardItem.x, y: cardItem.y }
                                root.positions = next
                                // Skip self so a container being dragged
                                // doesn't claim itself as a target.
                                const cx = cardItem.x + cardItem.width / 2
                                const cy = cardItem.y + cardItem.height / 2
                                const idx = _containerAt(cx, cy)
                                root.hoveredContainerIndex =
                                    (idx === model.index) ? -1 : idx
                            }
                        }
                        onReleased: (mouse) => {
                            // onPressed already popped the menu.
                            if (mouse.button === Qt.RightButton) return
                            if (_wasDragged) {
                                // Reparent if dropped on a container.
                                const cx = cardItem.x + cardItem.width / 2
                                const cy = cardItem.y + cardItem.height / 2
                                const targetIdx = _containerAt(cx, cy)
                                root.hoveredContainerIndex = -1
                                if (targetIdx >= 0 && targetIdx !== model.index) {
                                    root.moveStepToContainerRequested(
                                        model.index, targetIdx)
                                    return
                                }
                                const next = Object.assign({}, root.positions)
                                next[cardItem.stepId] = { x: cardItem.x, y: cardItem.y }
                                root.positions = next
                            } else {
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

                            // Always laid out; opacity gates visibility
                            // so the kind label never sits behind it.
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
                                // Reset opacity so the dot doesn't stick
                                // at a mid-pulse value after stopping.
                                onIsActiveLikeChanged: if (!cardItem.isActive) opacity = 1.0
                                readonly property bool isActiveLike: cardItem.isActive

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

                        // Library-style chip: pill + category dot + the
                        // same abbreviation rules wflows.io uses for trail
                        // summaries. Replaces the older 36px GradientPill
                        // so the editor and library read as one product.
                        // Stretched + bumped slightly so it reads as the
                        // card's hero, not a tiny inline tag.
                        StepChip {
                            kind: cardItem.kind
                            value: cardItem.act
                                ? (cardItem.act.editable
                                    ? (cardItem.act.rawPrimary || "")
                                    : (cardItem.act.value || ""))
                                : ""
                            width: parent.width
                            height: 28
                            fontSize: 12
                        }

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

                        // Inner-step drop zone for repeat containers.
                        // Border highlights on hover-drop.
                        Rectangle {
                            id: innerZone
                            visible: cardItem.isContainer
                            width: parent.width
                            // 108 = open button (6 + 28) + space for
                            // the centred empty-state placeholder.
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

                            // Click enters this container as the canvas
                            // root; the page surfaces a breadcrumb.
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
                            // 42 = 6 topMargin + 28 Open button + 8 gap.
                            anchors.topMargin: 42
                            spacing: 3

                            // Notes round-trip through KDL but don't
                            // render as inline rows.
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
                                            // <=14 hits the min(10) floor and
                                            // every kind glyph collapses to identical 10px.
                                            size: 18
                                            hovered: false
                                        }
                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            // num(14) + space(6) + icon(18) + space(6)
                                            // + dot(7) + space(6) + del(22) + space(6)
                                            width: parent.width - 14 - 6 - 18 - 6 - 7 - 6 - 22 - 6
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
                                            // the cxx-qt setter, QML never sees the
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

                    // Child of the card so stepIdx captures bind to
                    // this delegate.
                    WfMenu {
                        id: rewireMenu

                        WfMenuItem {
                            text: "↑  PRECEDED BY"
                            enabled: false
                        }
                        Repeater {
                            model: root.actions
                            delegate: WfMenuItem {
                                // Skip self, current predecessor (no-op),
                                // and the next card (predecessor swap
                                // would also be a no-op).
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

        // z > 100 so port dots stay above a card mid-drag (cards bump
        // their z to 100 while dragging).
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
                        _routeWire(fromPos, toPos, fromH, toH, fromW, toW, toId)
                    visible: fromPos !== undefined && toPos !== undefined

                    Rectangle {
                        x: route.sx - root._portR
                        y: route.sy - root._portR
                        width: root._portR * 2
                        height: root._portR * 2
                        radius: width / 2
                        color: Theme.accent
                        border.color: Theme.accentLo
                        border.width: 1
                    }

                    Rectangle {
                        x: route.tx - root._portR
                        y: route.ty - root._portR
                        width: root._portR * 2
                        height: root._portR * 2
                        radius: width / 2
                        color: Theme.accent
                        border.color: Theme.accentLo
                        border.width: 1
                    }
                }
            }
        }
        }   // end of world Item
    }       // end of Flickable

    // Parented to Overlay.overlay so the ghost renders above every
    // card. A sibling at z:200 inside the Flickable still got tucked
    // under cards in practice.
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
            // Match the canvas card's hero chip so the drag preview
            // resolves visually into a real card on drop.
            StepChip {
                kind: root.ghostKind
                overrideLabel: "(new step)"
                width: parent.width
                height: 28
                fontSize: 12
            }
        }
    }

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

    readonly property int toolDockCollapsedW: 56
    readonly property int toolDockExpandedW: 200

    Rectangle {
        id: toolDock
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: 12
        // Child MouseAreas with hoverEnabled steal QHoverEvent from a
        // dock-level HoverHandler. Each button bumps this counter
        // instead so the dock knows it's hovered through a button.
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
                    onContainsMouseChanged: {
                        toolDock.chipHoverCount = Math.max(
                            0,
                            toolDock.chipHoverCount + (containsMouse ? 1 : -1))
                    }
                }
            }
        }

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

            Loader {
                sourceComponent: toolBtnComp
                onLoaded: {
                    item.glyph = "✦"
                    item.tip = "Smart tidy, picks the layout that keeps cards readable"
                    item.label = "Tidy smart"
                    item.onActivate = () => organizeSmart()
                }
            }
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

            // Wire-style toggle.
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
                    onContainsMouseChanged: {
                        toolDock.chipHoverCount = Math.max(
                            0,
                            toolDock.chipHoverCount + (containsMouse ? 1 : -1))
                    }
                }
            }

            Loader { sourceComponent: toolDivComp }

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
                    // Reset to 1:1 while keeping the centre world point
                    // at the centre. contentWidth = world * zoom, so
                    // passing raw contentX/Y across the change strands
                    // the cards off-screen.
                    onClicked: {
                        const z = Math.max(0.01, root.zoom)
                        const worldCx = (flick.contentX + flick.width / 2) / z
                        const worldCy = (flick.contentY + flick.height / 2) / z
                        root._animateZoomTo(1.0,
                            worldCx - flick.width / 2,
                            worldCy - flick.height / 2)
                    }
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

    // Bezier control points pulled along source/target tangents so a
    // column-wrap wire sweeps cleanly out of source and into target
    // instead of cutting through cards in between.
    function _curvePath(route) {
        if (!route) return ""
        const sd = route.sd || (route.axis === "h" ? { x: 1, y: 0 } : { x: 0, y: 1 })
        const td = route.td || (route.axis === "h" ? { x: 1, y: 0 } : { x: 0, y: 1 })
        const dist = Math.hypot(route.tx - route.sx, route.ty - route.sy)
        // k scales with length: tight on adjacent cards, long enough
        // for column-wraps to lobe clearly off the right edges.
        const k = Math.max(40, Math.min(dist * 0.4, 240))
        const c1x = route.sx + sd.x * k
        const c1y = route.sy + sd.y * k
        const c2x = route.tx - td.x * k
        const c2y = route.ty - td.y * k
        return "M " + route.sx + " " + route.sy
             + " C " + c1x + " " + c1y
             + " "   + c2x + " " + c2y
             + " "   + route.tx + " " + route.ty
    }

    // Forward flow = three-segment Z. Back-flow routes the long segment
    // through a real gap so the elbow doesn't cut back through cards.
    function _orthoPath(route) {
        if (!route) return ""
        const sd = route.sd || (route.axis === "h" ? { x: 1, y: 0 } : { x: 0, y: 1 })
        const td = route.td || (route.axis === "h" ? { x: 1, y: 0 } : { x: 0, y: 1 })
        const padX = 24
        const padY = 24
        if (route.axis === "h") {
            const forward = sd.x > 0 && td.x > 0 && route.tx > route.sx
            if (forward) {
                const midX = (route.sx + route.tx) / 2
                return "M " + route.sx + " " + route.sy
                     + " L " + midX     + " " + route.sy
                     + " L " + midX     + " " + route.ty
                     + " L " + route.tx + " " + route.ty
            }
            // Back-flow: when cards share a row (yDelta small), detour
            // above by a card-height so the segment misses them.
            const yDelta = Math.abs(route.ty - route.sy)
            const midY = yDelta > 80
                ? (route.sy + route.ty) / 2
                : Math.min(route.sy, route.ty) - 80
            return "M " + route.sx + " " + route.sy
                 + " L " + (route.sx + sd.x * padX) + " " + route.sy
                 + " L " + (route.sx + sd.x * padX) + " " + midY
                 + " L " + (route.tx - td.x * padX) + " " + midY
                 + " L " + (route.tx - td.x * padX) + " " + route.ty
                 + " L " + route.tx + " " + route.ty
        } else {
            const forward = sd.y > 0 && td.y > 0 && route.ty > route.sy
            if (forward) {
                const midY = (route.sy + route.ty) / 2
                return "M " + route.sx + " " + route.sy
                     + " L " + route.sx + " " + midY
                     + " L " + route.tx + " " + midY
                     + " L " + route.tx + " " + route.ty
            }
            // Back-flow: when cards share a column (xDelta small), detour
            // right by a card-width so the segment misses them.
            const xDelta = Math.abs(route.tx - route.sx)
            const midX = xDelta > 80
                ? (route.sx + route.tx) / 2
                : Math.max(route.sx, route.tx) + 100
            return "M " + route.sx + " " + route.sy
                 + " L " + route.sx + " " + (route.sy + sd.y * padY)
                 + " L " + midX     + " " + (route.sy + sd.y * padY)
                 + " L " + midX     + " " + (route.ty - td.y * padY)
                 + " L " + route.tx + " " + (route.ty - td.y * padY)
                 + " L " + route.tx + " " + route.ty
        }
    }

    // Wire endpoint picker.
    //
    // Vertical axis: always source-bottom → target-top. Horizontal
    // axis: exit right, enter left when target is to the right.
    //
    // Axis pick: same row → horizontal; same column → vertical;
    // overlap or diagonal → larger centre-delta wins.
    // _hasObstacleAbove: true if a card overlaps target's X range and
    // ends above target's top, meaning a top-entry wire would cross
    // it. Triggers a swap to bottom-entry. Linear over actions; cheap
    // sizes.
    function _hasCardAbove(tx, ty, tw, ignoreId) {
        const list = root.actions || []
        for (let i = 0; i < list.length; i++) {
            const a = list[i]
            if (!a || a.id === ignoreId) continue
            const p = positions[a.id]
            if (!p) continue
            const w = cardWidths[a.id] || _widthForKind(a.rawKind)
            const h = cardHeights[a.id] || nodeMinH
            const xOverlap = !(p.x + w <= tx || tx + tw <= p.x)
            if (xOverlap && p.y + h <= ty) return true
        }
        return false
    }

    function _routeWire(fromPos, toPos, fromH, toH, fromW, toW, toId) {
        if (!fromPos || !toPos) {
            return {
                sx: 0, sy: 0, tx: 0, ty: 0, axis: "v",
                sd: { x: 0, y: 1 }, td: { x: 0, y: 1 }
            }
        }
        if (!fromW) fromW = nodeW
        if (!toW)   toW   = nodeW
        const fromCx = fromPos.x + fromW / 2
        const fromCy = fromPos.y + fromH / 2
        const toCx = toPos.x + toW / 2
        const toCy = toPos.y + toH / 2

        const xOverlap = !(fromPos.x + fromW <= toPos.x || toPos.x + toW <= fromPos.x)
        const yOverlap = !(fromPos.y + fromH <= toPos.y || toPos.y + toH <= fromPos.y)

        // Same row (y overlap, no x overlap) → horizontal.
        // Same column (x overlap, no y overlap) → vertical.
        // Diagonal (no overlap on either axis) → horizontal, so column-
        //   wrap wires arc out the side edges. Choosing vertical here
        //   tunnels the wire over the top of intermediate cards in the
        //   source column (the tidy-smart 2-column case where the last
        //   card of column 1's wire flew up over all cards above it).
        // Cards overlap on both axes (stacked) → larger centre-delta wins.
        let useVertical
        if (yOverlap && !xOverlap) {
            useVertical = false
        } else if (!yOverlap && xOverlap) {
            useVertical = true
        } else if (!yOverlap && !xOverlap) {
            useVertical = false
        } else {
            const dx = toCx - fromCx
            const dy = toCy - fromCy
            useVertical = Math.abs(dy) >= Math.abs(dx)
        }

        if (useVertical) {
            // Forward: bottom→top. Back-flow with cards above target
            // (no clearance for top-entry): dive under, enter bottom.
            // Other back-flow: top→bottom going up, no pointless U.
            const isBackFlow = toCy < fromCy
            if (isBackFlow && _hasCardAbove(toPos.x, toPos.y, toW, toId)) {
                return {
                    sx: fromCx, sy: fromPos.y + fromH,
                    tx: toCx,   ty: toPos.y + toH,
                    axis: "v",
                    sd: { x: 0, y: 1 },
                    td: { x: 0, y: -1 }
                }
            }
            if (isBackFlow) {
                return {
                    sx: fromCx, sy: fromPos.y,
                    tx: toCx,   ty: toPos.y + toH,
                    axis: "v",
                    sd: { x: 0, y: -1 },
                    td: { x: 0, y: -1 }
                }
            }
            return {
                sx: fromCx, sy: fromPos.y + fromH,
                tx: toCx,   ty: toPos.y,
                axis: "v",
                sd: { x: 0, y: 1 },
                td: { x: 0, y: 1 }
            }
        } else {
            // Forward: source-right → target-left.
            // Back-flow: source-left → target-right (mirror).
            const isHBackFlow = toCx < fromCx
            if (isHBackFlow) {
                return {
                    sx: fromPos.x, sy: fromCy,
                    tx: toPos.x + toW, ty: toCy,
                    axis: "h",
                    sd: { x: -1, y: 0 },
                    td: { x: -1, y: 0 }
                }
            }
            return {
                sx: fromPos.x + fromW, sy: fromCy,
                tx: toPos.x,            ty: toCy,
                axis: "h",
                sd: { x: 1, y: 0 },
                td: { x: 1, y: 0 }
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

    // Inner steps carry actions.rs raw kind names; project to the
    // shaped names the canvas / CategoryIcon use.
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
