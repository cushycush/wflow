import QtQuick
import QtQuick.Controls
import Wflow

// Workflow editor. WorkflowController loads on mount, edits debounce-save
// at ~600ms, step progress streams via active_step + step_done signals.
Item {
    id: root
    property string workflowId: ""
    // Read-only fragment mode for `use NAME` cards.
    property string fragmentPath: ""
    readonly property bool fragmentMode: fragmentPath.length > 0

    // TutorialCoach reads these to point at editor regions.
    property alias canvasArea: canvasView
    property alias paletteDock: paletteDockInst
    property alias inspectorPanel: inspectorContainer
    property alias runButton: runBtn
    property alias stepRail: rail

    signal backRequested()
    signal openFragmentRequested(string path, string displayName)

    WorkflowController { id: wfCtrl }
    StateController { id: stateCtrl }
    LibraryController {
        id: libCtrl
        Component.onCompleted: libCtrl.start_watching()
    }

    // Source-file mtime we last saw for this workflow. Lets the
    // watcher distinguish "this workflow's .kdl actually changed on
    // disk" from "some sibling workflow got saved on the Library page
    // and our libCtrl re-emitted." Chord rebinds and hand-edits both
    // bump the file mtime, so this one signal covers both.
    property double _lastSeenDiskMtime: 0

    function _libSummaryFor(id) {
        if (!id || id.length === 0) return null
        let arr = []
        try {
            arr = JSON.parse(libCtrl.workflows) || []
        } catch (e) { return null }
        for (let i = 0; i < arr.length; ++i) {
            if (arr[i] && arr[i].id === id) return arr[i]
        }
        return null
    }

    // libCtrl's notify watcher fires on any workflows-dir change.
    // Reload only when THIS workflow's source file changed: a sibling
    // workflow getting saved on the Library page shouldn't force a
    // full editor rebuild. The FS event from our own write also lands
    // here, so we adopt the new mtime in mid-save states without
    // reloading; that keeps the post-save tail event from re-rendering
    // the canvas over content we just authored.
    Connections {
        target: libCtrl
        function onWorkflowsChanged() {
            if (root.fragmentMode) return
            if (root.workflowId.length === 0) return
            const summary = root._libSummaryFor(root.workflowId)
            if (!summary) return
            const mtime = Number(summary.disk_mtime || 0)
            if (mtime === 0) return
            const prev = root._lastSeenDiskMtime
            if (prev === 0) {
                // First snapshot for this workflow: adopt without reloading.
                root._lastSeenDiskMtime = mtime
                return
            }
            if (mtime === prev) return
            if (root.saveState !== "idle") {
                // Our own write (or an in-flight edit). Skip the reload,
                // but adopt the new mtime so we don't re-fire after we
                // settle back to idle.
                root._lastSeenDiskMtime = mtime
                return
            }
            root._lastSeenDiskMtime = mtime
            wfCtrl.load(root.workflowId)
        }
    }

    // Held locally so the editor has a live target to mutate before
    // load() returns and during in-flight edits.
    property var workflow: ({
        id: "",
        title: "Untitled workflow",
        subtitle: "",
        steps: []
    })

    // idle → dirty → saving → saved → idle, or error on failure.
    property string saveState: "idle"

    property var stepStatuses: ({})
    // Keyed by stable step_id so canvas inner steps (repeat children)
    // can find their own status. stepStatuses still aggregates onto
    // top-level cards.
    property var stepStatusesById: ({})

    property string trustSummary: ""

    // Session-only; long-term flag is state.toml tutorials.blank_workflow_seen.
    property bool _tutorialDismissedThisSession: false
    readonly property bool _shouldShowBlankTutorial:
        root.workflowId.length > 0
        && (root.workflow.steps || []).length === 0
        && !root._tutorialDismissedThisSession
        && !stateCtrl.tutorial_seen("blank_workflow")

    readonly property string title:    workflow.title || "Untitled workflow"
    readonly property string subtitle: workflow.subtitle || ""
    // ID match instead of flat-index because falsy conditionals skip
    // inner steps and the flat-index path would miscount.
    readonly property int activeStepIndex: {
        const id = wfCtrl.active_step_id || ""
        if (id.length === 0) return -1
        const arr = root.actions || []
        for (let i = 0; i < arr.length; i++) {
            if (arr[i] && arr[i].id === id) return i
        }
        return -1
    }
    // Engine doesn't emit StepStart for conditionals themselves, so
    // light up the parent here when an inner is running.
    readonly property int activeParentIndex: {
        const i = activeStepIndex
        if (i < 0) return -1
        const arr = root.actions || []
        const a = arr[i]
        if (!a || a._displayKind !== "inner") return -1
        for (let j = 0; j < arr.length; j++) {
            const candidate = arr[j]
            if (candidate && candidate._displayKind === "top"
                && candidate._topIdx === a._parentTopIdx) {
                return j
            }
        }
        return -1
    }

    function _flatLeafCount(step) {
        const a = step ? step.action : null
        if (!a) return 1
        if (a.kind === "conditional") {
            return _flatLeafCountList(a.steps || [])
        }
        if (a.kind === "repeat") {
            return _flatLeafCountList(a.steps || []) * (a.count || 1)
        }
        return 1
    }
    function _flatLeafCountList(steps) {
        let total = 0
        for (const s of (steps || [])) total += _flatLeafCount(s)
        return total
    }

    function _findActionsIdx(predicate) {
        const arr = root.actions || []
        for (let i = 0; i < arr.length; i++) {
            if (predicate(arr[i])) return i
        }
        return -1
    }

    function _flatToActionsIdx(flatIndex) {
        if (flatIndex < 0) return -1
        const steps = _stepsAtCrumb(root.workflow) || []
        let cursor = 0
        for (let i = 0; i < steps.length; i++) {
            const step = steps[i]
            const a = step ? step.action : null
            if (a && a.kind === "conditional") {
                const inner = a.steps || []
                for (let j = 0; j < inner.length; j++) {
                    const innerLen = _flatLeafCount(inner[j])
                    if (flatIndex >= cursor && flatIndex < cursor + innerLen) {
                        return _findActionsIdx(x => x && x._displayKind === "inner"
                            && x._parentTopIdx === i && x._innerIdx === j)
                    }
                    cursor += innerLen
                }
                continue
            }
            // Repeat container leaves all aggregate onto the repeat card.
            const len = _flatLeafCount(step)
            if (flatIndex >= cursor && flatIndex < cursor + len) {
                return _findActionsIdx(x => x && x._displayKind === "top"
                    && x._topIdx === i)
            }
            cursor += len
        }
        return -1
    }
    readonly property bool running: wfCtrl.running

    // Each entry is an index into the step list at the previous depth.
    // [] = top, [3] = wf.steps[3]'s inner list, [3,1] = nested.
    property var crumb: []

    // View-source pane state. Open re-encodes the live workflow as KDL
    // through wfCtrl.workflow_to_kdl(...) and renders it in a slide-over
    // on the right of the canvas. Reset on workflow switch.
    property bool sourcePaneOpen: false
    property string sourcePaneCopyHint: ""
    readonly property string sourceKdl: sourcePaneOpen
        ? wfCtrl.workflow_to_kdl(JSON.stringify(root.workflow))
        : ""
    // Highlight spans for the source pane. Tokenized in Rust so the
    // keyword set stays in lockstep with the parser; QML only paints.
    // `[]` when the pane is closed so the empty state is dirt-cheap.
    readonly property string sourceSpansJson: sourcePaneOpen && sourceKdl.length > 0
        ? wfCtrl.tokenize_kdl(sourceKdl)
        : "[]"

    // Pure read helper. Mutators clone wf and walk it themselves.
    function _stepsAtCrumb(wf) {
        let steps = wf && wf.steps ? wf.steps : []
        for (let i = 0; i < root.crumb.length; ++i) {
            const idx = root.crumb[i]
            if (idx < 0 || idx >= steps.length) return null
            const a = steps[idx].action
            if (!a || !Array.isArray(a.steps)) return null
            steps = a.steps
        }
        return steps
    }

    readonly property var _currentSteps: _stepsAtCrumb(workflow) || []

    // Reactive so editing a condition in the inspector updates the chip.
    readonly property var crumbLabels: {
        const out = [root.title]
        let steps = root.workflow && root.workflow.steps ? root.workflow.steps : []
        for (let i = 0; i < root.crumb.length; ++i) {
            const idx = root.crumb[i]
            if (idx < 0 || idx >= steps.length) { out.push("?"); break }
            const a = steps[idx].action
            if (!a) { out.push("?"); break }
            if (a.kind === "repeat") {
                out.push("repeat × " + (a.count || 1))
            } else if (a.kind === "conditional") {
                const verb = a.negate ? "unless" : "when"
                out.push(verb + " " + _condSummary(a.cond))
            } else {
                out.push("?")
            }
            steps = (a && Array.isArray(a.steps)) ? a.steps : []
        }
        return out
    }

    function pushCrumb(stepIndex) {
        const steps = root._currentSteps
        if (stepIndex < 0 || stepIndex >= steps.length) return
        const action = steps[stepIndex].action
        if (!action) return
        if (action.kind !== "repeat" && action.kind !== "conditional") return
        root.crumb = root.crumb.concat([stepIndex])
        editorContent._setSingleSelection(-1)
        editorContent.selectedInnerIndex = -1
        // _placeNewSteps seeds default positions on the next tick;
        // fit after that so the user lands on the cards, not empty canvas.
        Qt.callLater(canvasView._zoomToFit)
    }

    function popCrumbTo(depth) {
        if (depth < 0) depth = 0
        if (depth >= root.crumb.length) return
        root.crumb = root.crumb.slice(0, depth)
        editorContent._setSingleSelection(-1)
        editorContent.selectedInnerIndex = -1
        Qt.callLater(canvasView._zoomToFit)
    }

    readonly property var actions: {
        // Shape Rust Step[] into the canvas delegate format. Conditionals
        // are NOT visual containers; their inner steps surface as sibling
        // cards with fork/rejoin wires. _displayKind / _topIdx / _innerIdx
        // / _parentTopIdx feed layout + wire routing.
        const out = []
        const steps = root._currentSteps
        for (let i = 0; i < steps.length; i++) {
            const step = steps[i]
            // Notes used to render as soft annotation cards; group rects
            // do that job now, so they're filtered out of
            // the visual model entirely. The data round-trips
            // through KDL unchanged, old workflows with notes load
            // and re-save without losing them, but the canvas, the
            // rail, the engine pause, and indices skip past them.
            if (step.action && step.action.kind === "note") continue
            const shaped = root._stepToAction(step)
            shaped._displayKind = "top"
            shaped._topIdx = i
            shaped._innerIdx = -1
            shaped._parentTopIdx = -1
            out.push(shaped)
            // Conditionals additionally surface their inner steps as
            // siblings on the canvas. Repeat keeps the container
            // model, it's a loop, not a branch.
            //
            // Yes-side cards (the `steps` block) tag with
            // `_branchSide: "yes"`; no-side cards (the `else_steps`
            // block) tag with `_branchSide: "no"`. The canvas's
            // wire generator + layout passes branch on this so the
            // two columns lay out on opposite sides of the parent.
            if (step.action && step.action.kind === "conditional") {
                const yesInner = step.action.steps || []
                for (let j = 0; j < yesInner.length; j++) {
                    if (yesInner[j] && yesInner[j].action
                        && yesInner[j].action.kind === "note") continue
                    const innerShaped = root._stepToAction(yesInner[j])
                    innerShaped._displayKind = "inner"
                    innerShaped._topIdx = -1
                    innerShaped._innerIdx = j
                    innerShaped._parentTopIdx = i
                    innerShaped._branchSide = "yes"
                    out.push(innerShaped)
                }
                const noInner = step.action.else_steps || []
                for (let j = 0; j < noInner.length; j++) {
                    if (noInner[j] && noInner[j].action
                        && noInner[j].action.kind === "note") continue
                    const innerShaped = root._stepToAction(noInner[j])
                    innerShaped._displayKind = "inner"
                    innerShaped._topIdx = -1
                    innerShaped._innerIdx = j
                    innerShaped._parentTopIdx = i
                    innerShaped._branchSide = "no"
                    out.push(innerShaped)
                }
            }
        }
        return out
    }

    function _stepToAction(step) {
        const act = step.action || {}
        const kind = act.kind || "note"
        let shaped
        switch (kind) {
        case "wdo_type":            shaped = { kind: "type",     summary: "Type text",         value: act.text,                              rawPrimary: act.text,        editable: true }; break
        case "wdo_key":             shaped = { kind: "key",      summary: "Press key chord",   value: act.chord,                             rawPrimary: act.chord,       editable: true }; break
        case "wdo_key_down":        shaped = { kind: "key",      summary: "Hold key",          value: act.chord,                             rawPrimary: act.chord,       editable: true }; break
        case "wdo_key_up":          shaped = { kind: "key",      summary: "Release key",       value: act.chord,                             rawPrimary: act.chord,       editable: true }; break
        case "wdo_click":           shaped = { kind: "click",    summary: "Mouse click",       value: "button " + act.button,                rawPrimary: String(act.button), editable: true, intOnly: true }; break
        case "wdo_mouse_down":      shaped = { kind: "click",    summary: "Hold button",       value: "button " + act.button,                rawPrimary: String(act.button), editable: true, intOnly: true }; break
        case "wdo_mouse_up":        shaped = { kind: "click",    summary: "Release button",    value: "button " + act.button,                rawPrimary: String(act.button), editable: true, intOnly: true }; break
        case "wdo_mouse_move":      shaped = { kind: "move",     summary: "Move cursor",       value: "(" + act.x + ", " + act.y + ")",      rawPrimary: act.x + ", " + act.y, editable: false }; break
        case "wdo_scroll":          shaped = { kind: "scroll",   summary: "Scroll",            value: "dx " + act.dx + " dy " + act.dy,      rawPrimary: act.dx + ", " + act.dy, editable: false }; break
        case "wdo_activate_window": shaped = { kind: "focus",    summary: "Focus window",      value: act.name,                              rawPrimary: act.name,        editable: true }; break
        case "wdo_await_window":    shaped = { kind: "wait",     summary: "Wait for window",   value: act.name,                              rawPrimary: act.name,        editable: true }; break
        case "delay":               shaped = { kind: "wait",     summary: "Wait",              value: act.ms + " ms",                        rawPrimary: String(act.ms),  editable: true, intOnly: true, unit: "ms" }; break
        case "shell":               shaped = { kind: "shell",    summary: "Run shell command", value: act.command,                           rawPrimary: act.command,     editable: true }; break
        case "notify":              shaped = { kind: "notify",   summary: "Notify",            value: act.title,                             rawPrimary: act.title,       editable: true }; break
        case "clipboard":           shaped = { kind: "clipboard",summary: "Copy to clipboard", value: act.text,                              rawPrimary: act.text,        editable: true }; break
        case "note":                shaped = { kind: "note",     summary: "Note",              value: act.text,                              rawPrimary: act.text,        editable: true }; break
        // Conditionals: the primary edits the cond's main field
        // (window name / file path / env name). Mode (when vs unless),
        // predicate kind, and equals= live in the inspector's
        // condition section. Branch counts are deliberately absent
        // here — the canvas renders both branches as wires, so a
        // textual "1 yes / 1 else" tag was duplicate noise that ran
        // off the right edge of the inspector's value pill.
        case "repeat":      shaped = { kind: "repeat",  summary: "Repeat", value: act.count + "×, " + (act.steps || []).length + " inner step(s)", rawPrimary: String(act.count), editable: true, intOnly: true, unit: "×" }; break
        case "conditional": {
            const cond = act.cond || { kind: "window", name: "" }
            const primary = cond.kind === "file"
                ? (cond.path || "")
                : (cond.name || "")
            shaped = {
                kind: act.negate ? "unless" : "when",
                summary: act.negate ? "Unless" : "When",
                value: _condSummary(cond),
                rawPrimary: primary,
                editable: true
            }
            break
        }
        case "use":         shaped = { kind: "use",     summary: "Use import", value: act.name, rawPrimary: act.name, editable: true }; break
        default:                    shaped = { kind: "note", summary: kind, value: "", rawPrimary: "", editable: false }
        }
        // Inspector binds option editors directly off rawAction.
        shaped.id = step.id || ""
        shaped.rawKind = kind
        shaped.enabled = step.enabled !== false
        shaped.onError = step.on_error || "stop"
        shaped.rawAction = act
        shaped.note = step.note || ""
        return shaped
    }

    function _condSummary(cond) {
        if (!cond) return ""
        switch (cond.kind) {
        case "window": return "window = " + (cond.name || "")
        case "file":   return "file = "   + (cond.path || "")
        case "env":    return "env."      + (cond.name || "") + (cond.equals ? " = " + cond.equals : "")
        }
        return ""
    }

    // Kind-aware so "500" on a delay becomes {ms: 500}, not a string.
    function _mutateAction(oldAction, newPrimary) {
        const out = JSON.parse(JSON.stringify(oldAction))
        const kind = out.kind
        switch (kind) {
        case "wdo_type":            out.text    = newPrimary; break
        case "wdo_key":
        case "wdo_key_down":
        case "wdo_key_up":          out.chord   = newPrimary; break
        case "wdo_click":
        case "wdo_mouse_down":
        case "wdo_mouse_up":        {
            const n = parseInt(newPrimary, 10)
            if (isNaN(n) || n < 0) return oldAction
            out.button = n; break
        }
        case "wdo_activate_window":
        case "wdo_await_window":    out.name    = newPrimary; break
        case "delay": {
            const n = parseInt(newPrimary, 10)
            if (isNaN(n) || n < 0) return oldAction
            out.ms = n; break
        }
        case "shell":               out.command = newPrimary; break
        case "notify":              out.title   = newPrimary; break
        case "clipboard":           out.text    = newPrimary; break
        case "note":                out.text    = newPrimary; break
        case "use":                 out.name    = newPrimary; break
        case "repeat": {
            const n = parseInt(newPrimary, 10)
            if (isNaN(n) || n < 1) return oldAction
            out.count = n; break
        }
        case "conditional": {
            // Same field set as the inspector's condition section, but
            // editable from the top value pill: window/env reuse the
            // cond's `name`, file routes through `path`. Kind,
            // negate, and env's `equals` are preserved verbatim so a
            // top-bar edit doesn't blow them away.
            const oldCond = oldAction.cond || { kind: "window", name: "" }
            const k = oldCond.kind || "window"
            const nextCond = { kind: k }
            if (k === "file") {
                nextCond.path = newPrimary
            } else {
                nextCond.name = newPrimary
                if (k === "env" && oldCond.equals !== undefined && oldCond.equals !== null && oldCond.equals !== "") {
                    nextCond.equals = oldCond.equals
                }
            }
            out.cond = nextCond
            break
        }
        default: return oldAction
        }
        return out
    }

    // path is "enabled" | "on_error" | "note" | "action.<field>".
    // Empty value on an Option<T> action field deletes the key so
    // serde defaults round-trip cleanly.
    function _commitOption(stepIndex, path, value) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = _stepsAtCrumb(wf)
        if (!steps) return
        const step = _resolveStep(steps, stepIndex)
        if (!step) return
        if (path === "enabled") {
            if (step.enabled === value) return
            step.enabled = value
        } else if (path === "on_error") {
            if ((step.on_error || "stop") === value) return
            step.on_error = value
        } else if (path === "note") {
            // Empty clears so serde drops it and KDL doesn't carry note="".
            const isEmpty = value === null || value === undefined || value === ""
            if (isEmpty) {
                if (step.note === undefined || step.note === null || step.note === "") return
                delete step.note
            } else {
                if (step.note === value) return
                step.note = value
            }
        } else if (path.startsWith("action.")) {
            const key = path.slice(7)
            if (!step.action) return
            const isEmpty = value === null || value === undefined || value === ""
            if (isEmpty) {
                if (!(key in step.action)) return
                delete step.action[key]
            } else {
                if (step.action[key] === value) return
                step.action[key] = value
            }
        } else {
            return
        }
        root.workflow = wf
        _scheduleSave()
    }

    function _uuid() {
        // Rust side only requires `id` to be unique, not a real UUID.
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
            const r = Math.random() * 16 | 0
            const v = c === 'x' ? r : (r & 0x3 | 0x8)
            return v.toString(16)
        })
    }

    function _defaultActionForKind(kind) {
        switch (kind) {
        case "key":       return { kind: "wdo_key",             chord: "Return" }
        case "type":      return { kind: "wdo_type",            text:  "hello" }
        case "click":     return { kind: "wdo_click",           button: 1 }
        case "move":      return { kind: "wdo_mouse_move",      x: 0, y: 0, relative: false }
        case "scroll":    return { kind: "wdo_scroll",          dx: 0, dy: 0 }
        case "focus":     return { kind: "wdo_activate_window", name: "firefox" }
        case "wait":      return { kind: "delay",               ms: 500 }
        case "shell":     return { kind: "shell",               command: "echo hello" }
        case "notify":    return { kind: "notify",              title: "Done" }
        case "clipboard": return { kind: "clipboard",           text: "" }
        case "note":      return { kind: "note",                text: "" }
        case "when":      return { kind: "conditional", cond: { kind: "window", name: "" }, negate: false, steps: [] }
        case "unless":    return { kind: "conditional", cond: { kind: "window", name: "" }, negate: true,  steps: [] }
        case "repeat":    return { kind: "repeat",      count: 2, steps: [] }
        case "use":       return { kind: "use",         name: "" }
        }
        return { kind: "note", text: "" }
    }

    function _addStep(kind) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = _stepsAtCrumb(wf)
        if (!steps) return ""
        const id = _uuid()
        steps.push({
            id: id,
            enabled: true,
            on_error: "stop",
            action: _defaultActionForKind(kind)
        })
        root.workflow = wf
        editorContent._setSingleSelection(steps.length - 1)
        _scheduleSave()
        return id
    }

    // Position MUST be written before the workflow mutation; otherwise
    // _placeNewSteps fires synchronously, assigns a stack-below pos,
    // and the card animates from origin back to the drop spot.
    function _addStepAt(kind, x, y) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = _stepsAtCrumb(wf)
        if (!steps) return
        const id = _uuid()
        steps.push({
            id: id,
            enabled: true,
            on_error: "stop",
            action: _defaultActionForKind(kind)
        })
        const next = Object.assign({}, canvasView.positions)
        next[id] = { x: Math.max(0, x), y: Math.max(0, y) }
        canvasView.positions = next
        // No selection change: user dropped to place, not to edit.
        root.workflow = wf
        _scheduleSave()
    }

    function _deleteStep(stepIndex) {
        // stepIndex is a flat-actions index from the canvas (where
        // conditional inner steps surface as siblings). Resolve through
        // metadata before splicing, otherwise conditionals delete wrong.
        const acts = root.actions || []
        if (stepIndex < 0 || stepIndex >= acts.length) return
        const meta = acts[stepIndex]
        if (!meta) return

        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = _stepsAtCrumb(wf)
        if (!steps) return

        if (meta._displayKind === "inner") {
            const parentIdx = meta._parentTopIdx
            const innerIdx = meta._innerIdx
            if (parentIdx < 0 || parentIdx >= steps.length) return
            const parent = steps[parentIdx]
            // No-side cards splice into else_steps; everything else
            // (yes branch + repeat inner) goes into action.steps.
            const branchKey = meta._branchSide === "no" ? "else_steps" : "steps"
            const innerSteps = parent && parent.action ? parent.action[branchKey] : null
            if (!Array.isArray(innerSteps)) return
            if (innerIdx < 0 || innerIdx >= innerSteps.length) return
            innerSteps.splice(innerIdx, 1)
        } else {
            const i = meta._topIdx
            if (i < 0 || i >= steps.length) return
            steps.splice(i, 1)
        }

        root.workflow = wf
        const newLen = (root.actions || []).length
        if (newLen === 0) {
            editorContent._setSingleSelection(-1)
        } else if (editorContent.selectedIndex >= newLen) {
            editorContent._setSingleSelection(newLen - 1)
        }
        _scheduleSave()
    }

    // ---- Group rectangles ----
    //
    // Groups are decorative annotations on the canvas, coloured
    // rounded rects with a comment label, drawn behind the step
    // cards. They live on root.workflow.groups and round-trip through
    // the KDL `groups { ... }` block. The engine ignores them
    // entirely; they're for visual organisation only.
    function _newGroupId() { return "g-" + Math.floor(Math.random() * 1e9).toString(16) }
    function _addGroup(x, y, w, h) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        if (!wf.groups) wf.groups = []
        wf.groups.push({
            id: _newGroupId(),
            x: x, y: y, width: Math.max(120, w), height: Math.max(80, h),
            color: "accent",
            comment: ""
        })
        root.workflow = wf
        _scheduleSave()
    }
    function _addGroupAroundSelection() {
        const selected = Object.keys(editorContent.selectedIndices).map(Number)
        if (selected.length === 0) {
            _addGroup(160, 160, 320, 200)
            return
        }
        const acts = root.actions || []
        let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
        for (const i of selected) {
            const a = acts[i]
            if (!a) continue
            const pos = canvasView.positions[a.id]
            if (!pos) continue
            const cw = canvasView.cardWidths[a.id] || canvasView._widthForKind(a.rawKind)
            const ch = canvasView.cardHeights[a.id] || canvasView.nodeMinH
            if (pos.x < minX) minX = pos.x
            if (pos.y < minY) minY = pos.y
            if (pos.x + cw > maxX) maxX = pos.x + cw
            if (pos.y + ch > maxY) maxY = pos.y + ch
        }
        if (!isFinite(minX)) {
            _addGroup(160, 160, 320, 200)
            return
        }
        const pad = 24
        _addGroup(minX - pad, minY - pad, (maxX - minX) + pad * 2, (maxY - minY) + pad * 2)
    }
    function _moveGroup(id, x, y) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        if (!wf.groups) return
        const g = wf.groups.find(g => g.id === id)
        if (!g) return
        g.x = x
        g.y = y
        root.workflow = wf
        _scheduleSave()
    }
    function _resizeGroup(id, x, y, w, h) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        if (!wf.groups) return
        const g = wf.groups.find(g => g.id === id)
        if (!g) return
        g.x = x
        g.y = y
        g.width = w
        g.height = h
        root.workflow = wf
        _scheduleSave()
    }
    function _deleteGroup(id) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        if (!wf.groups) return
        wf.groups = wf.groups.filter(g => g.id !== id)
        root.workflow = wf
        _scheduleSave()
    }
    function _editGroupComment(id, comment) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        if (!wf.groups) return
        const g = wf.groups.find(g => g.id === id)
        if (!g) return
        g.comment = comment
        root.workflow = wf
        _scheduleSave()
    }
    function _editGroupColor(id, color) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        if (!wf.groups) return
        const g = wf.groups.find(g => g.id === id)
        if (!g) return
        g.color = color
        root.workflow = wf
        _scheduleSave()
    }

    // Iterate descending so each splice doesn't invalidate the indices
    // we haven't processed yet.
    function _bulkDeleteSelected() {
        const indices = Object.keys(editorContent.selectedIndices)
            .map(Number)
            .filter(n => Number.isInteger(n) && n >= 0)
            .sort((a, b) => b - a)
        if (indices.length === 0) return
        for (const i of indices) {
            _deleteStep(i)
        }
        editorContent._clearSelection()
    }

    // ---- Copy / Paste as KDL ----
    //
    // Selection → KDL fragment → system clipboard, and back. The same
    // text is what `wflow daemon` parses on disk and what wflows.io
    // exchanges, so a snippet copied from the canvas pastes cleanly
    // into a chat / README / GitHub issue and back.

    function _withFreshIds(step) {
        const out = JSON.parse(JSON.stringify(step))
        out.id = _uuid()
        if (out.action) {
            if (Array.isArray(out.action.steps)) {
                out.action.steps = out.action.steps.map(_withFreshIds)
            }
            if (Array.isArray(out.action.else_steps)) {
                out.action.else_steps = out.action.else_steps.map(_withFreshIds)
            }
        }
        return out
    }

    function _stepsForIndices(indices) {
        const acts = root.actions || []
        const steps = root._currentSteps
        // First pass: which top-level conditionals are themselves
        // selected? Their inner cards are already part of the parent's
        // step tree, so a duplicate selection of an inner would copy
        // it twice.
        const selectedTopIdxs = new Set()
        for (const i of indices) {
            const meta = acts[i]
            if (meta && meta._displayKind === "top") selectedTopIdxs.add(meta._topIdx)
        }
        const collected = []
        const seen = new Set()
        for (const i of indices) {
            if (i >= acts.length) continue
            const meta = acts[i]
            if (!meta) continue
            let key, step
            if (meta._displayKind === "inner") {
                if (selectedTopIdxs.has(meta._parentTopIdx)) continue
                const parent = steps[meta._parentTopIdx]
                const branchKey = meta._branchSide === "no" ? "else_steps" : "steps"
                const innerSteps = parent && parent.action ? parent.action[branchKey] : null
                if (!Array.isArray(innerSteps)) continue
                step = innerSteps[meta._innerIdx]
                key = "inner:" + meta._parentTopIdx + ":" + meta._branchSide + ":" + meta._innerIdx
            } else {
                step = steps[meta._topIdx]
                key = "top:" + meta._topIdx
            }
            if (!step || seen.has(key)) continue
            seen.add(key)
            collected.push(step)
        }
        return collected
    }

    function _collectSelectedSteps() {
        const indices = Object.keys(editorContent.selectedIndices)
            .map(Number)
            .filter(n => Number.isInteger(n) && n >= 0)
            .sort((a, b) => a - b)
        return _stepsForIndices(indices)
    }

    function _copyStepsByIndicesAsKdl(indices) {
        const collected = _stepsForIndices(indices)
        if (collected.length === 0) return false
        return wfCtrl.copy_steps_to_clipboard(JSON.stringify(collected))
    }

    function _copySelectionAsKdl() {
        const collected = _collectSelectedSteps()
        if (collected.length === 0) return false
        return wfCtrl.copy_steps_to_clipboard(JSON.stringify(collected))
    }

    // Right-click on a card. Mirror VS Code: if the right-clicked card
    // is part of the current selection, copy the whole selection;
    // otherwise treat the right-click as the selection.
    function _copyMenuTarget(stepIndex) {
        const sel = editorContent.selectedIndices || {}
        if (sel[stepIndex]) return _copySelectionAsKdl()
        return _copyStepsByIndicesAsKdl([stepIndex])
    }

    function _insertKdlJsonIntoCurrent(json) {
        // Empty / non-array / empty-array all mean "nothing to insert,"
        // bridge has already set last_error if it was a parse failure.
        if (!json || json.length === 0) return false
        let pasted
        try { pasted = JSON.parse(json) } catch (e) { return false }
        if (!Array.isArray(pasted) || pasted.length === 0) return false
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const target = _stepsAtCrumb(wf)
        if (!target) return false
        const newIds = []
        for (const step of pasted) {
            const fresh = _withFreshIds(step)
            target.push(fresh)
            newIds.push(fresh.id)
        }
        root.workflow = wf
        // Reselect the freshly inserted top-level cards so the user
        // sees what landed.
        Qt.callLater(() => {
            const acts = root.actions || []
            const next = {}
            let lastIdx = -1
            for (let i = 0; i < acts.length; i++) {
                const a = acts[i]
                if (a && a._displayKind === "top" && newIds.indexOf(a.id) >= 0) {
                    next[i] = true
                    lastIdx = i
                }
            }
            editorContent.selectedIndices = next
            editorContent.selectedIndex = lastIdx
        })
        _scheduleSave()
        return true
    }

    function _pasteKdlIntoCurrent() {
        return _insertKdlJsonIntoCurrent(wfCtrl.paste_steps_from_clipboard())
    }

    function _importKdlFileIntoCurrent(localPath) {
        return _insertKdlJsonIntoCurrent(wfCtrl.steps_from_kdl_path(localPath))
    }

    // Qt's DropArea hands URLs over as `file://...` with percent-encoded
    // path bytes. Strip the scheme, decodeURIComponent the rest, hand
    // a plain path to the bridge.
    function _localPathFromDropUrl(url) {
        const s = (url + "").trim()
        if (!s) return ""
        const stripped = s.replace(/^file:\/\//, "")
        try { return decodeURIComponent(stripped) }
        catch (e) { return stripped }
    }

    function _makePredecessorOf(stepIdx, otherIdx) {
        if (stepIdx < 0 || otherIdx < 0 || otherIdx === stepIdx) return
        const target = otherIdx < stepIdx ? stepIdx - 1 : stepIdx
        _moveStep(otherIdx, target)
    }

    function _makeSuccessorOf(stepIdx, otherIdx) {
        if (stepIdx < 0 || otherIdx < 0 || otherIdx === stepIdx) return
        const target = otherIdx > stepIdx ? stepIdx + 1 : stepIdx
        _moveStep(otherIdx, target)
    }

    // `from` / `to` are shaped-actions indices (the form the rail and
    // the inspector pickers use). The raw KDL step list filters out
    // notes and surfaces conditional inners as siblings, so a shaped
    // index can sit past the end of the raw list whenever the
    // workflow has either. Translate via _topIdx before splicing into
    // the raw list, and reject moves whose endpoints aren't top-level
    // (inner-conditional cards aren't reorderable through this path).
    function _moveStep(from, to) {
        if (from === to) return
        const arr = root.actions || []
        const fromMeta = arr[from]
        const toMeta = arr[to]
        if (!fromMeta || fromMeta._displayKind !== "top") return
        if (!toMeta || toMeta._displayKind !== "top") return
        const fromRaw = fromMeta._topIdx
        const toRaw = toMeta._topIdx
        if (fromRaw === toRaw) return
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = _stepsAtCrumb(wf)
        if (!steps) return
        if (fromRaw < 0 || fromRaw >= steps.length) return
        if (toRaw < 0 || toRaw >= steps.length) return
        const [moved] = steps.splice(fromRaw, 1)
        steps.splice(toRaw, 0, moved)
        root.workflow = wf
        // Selection update stays in shaped space: after the shaped list
        // recomputes from the new workflow, the moved card lands at
        // shaped index `to`.
        const sel = editorContent.selectedIndex
        if (sel === from) {
            editorContent._setSingleSelection(to)
        } else if (from < sel && to >= sel) {
            editorContent._setSingleSelection(sel - 1)
        } else if (from > sel && to <= sel) {
            editorContent._setSingleSelection(sel + 1)
        }
        _scheduleSave()
    }

    // Translates a shaped-actions index (notes filtered, conditional
    // inners surfaced as siblings) to the raw Step in the tree.
    // Without this, editing any step after a note silently mutated
    // a different raw step and the inspector looked like it was
    // eating typing.
    function _resolveStep(steps, stepIndex) {
        const list = root.actions || []
        if (stepIndex < 0 || stepIndex >= list.length) return null
        const meta = list[stepIndex]
        if (!meta) return null

        if (meta._displayKind === "inner") {
            const parentIdx = meta._parentTopIdx
            const innerIdx = meta._innerIdx
            if (parentIdx < 0 || parentIdx >= steps.length) return null
            const parent = steps[parentIdx]
            const branchKey = meta._branchSide === "no" ? "else_steps" : "steps"
            const branch = parent.action ? parent.action[branchKey] : null
            if (!Array.isArray(branch)) return null
            if (innerIdx < 0 || innerIdx >= branch.length) return null
            return branch[innerIdx]
        }

        // selectedInnerIndex >= 0 means a repeat-container inline row.
        const topIdx = meta._topIdx
        if (topIdx < 0 || topIdx >= steps.length) return null
        const inner = editorContent.selectedInnerIndex
        if (inner < 0) return steps[topIdx]
        const parent = steps[topIdx]
        if (!parent.action || !Array.isArray(parent.action.steps)) return null
        if (inner >= parent.action.steps.length) return null
        return parent.action.steps[inner]
    }

    function _commitStepEdit(stepIndex, newPrimary) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = _stepsAtCrumb(wf)
        if (!steps) return
        const target = _resolveStep(steps, stepIndex)
        if (!target) return
        const oldAction = target.action || {}
        const newAction = _mutateAction(oldAction, newPrimary)
        if (JSON.stringify(newAction) === JSON.stringify(oldAction)) return
        target.action = newAction
        root.workflow = wf
        _scheduleSave()
    }

    function _setImport(name, path) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        if (!wf.imports) wf.imports = {}
        wf.imports[name] = path
        root.workflow = wf
        _scheduleSave()
    }

    function _renameImport(oldName, newName) {
        if (oldName === newName || !newName) return
        const wf = JSON.parse(JSON.stringify(root.workflow))
        if (!wf.imports || !(oldName in wf.imports)) return
        const path = wf.imports[oldName]
        delete wf.imports[oldName]
        wf.imports[newName] = path
        root.workflow = wf
        _scheduleSave()
    }

    function _deleteImport(name) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        if (!wf.imports || !(name in wf.imports)) return
        delete wf.imports[name]
        root.workflow = wf
        _scheduleSave()
    }

    function _commitCondition(stepIndex, newCond) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = _stepsAtCrumb(wf)
        if (!steps) return
        const step = _resolveStep(steps, stepIndex)
        if (!step || !step.action || step.action.kind !== "conditional") return
        step.action.cond = newCond
        root.workflow = wf
        _scheduleSave()
    }

    // Read off shaped actions (not _currentSteps) so use cards inside
    // conditionals also resolve.
    function _openUseImport(stepIndex) {
        const acts = root.actions || []
        if (stepIndex < 0 || stepIndex >= acts.length) return
        const act = acts[stepIndex]
        if (!act || act.rawKind !== "use") return
        const name = (act.rawAction && act.rawAction.name) || ""
        if (name.length === 0) return
        const abs = wfCtrl.resolve_import_path(name) || ""
        if (abs.length === 0) return
        root.openFragmentRequested(abs, name)
    }

    function _commitNegate(stepIndex, negate) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = _stepsAtCrumb(wf)
        if (!steps) return
        const step = _resolveStep(steps, stepIndex)
        if (!step || !step.action || step.action.kind !== "conditional") return
        if ((step.action.negate === true) === negate) return
        step.action.negate = negate
        root.workflow = wf
        _scheduleSave()
    }

    function _addInnerStep(stepIndex, kind) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = _stepsAtCrumb(wf)
        if (!steps) return
        if (stepIndex < 0 || stepIndex >= steps.length) return
        const action = steps[stepIndex].action
        if (!action) return
        if (!Array.isArray(action.steps)) action.steps = []
        action.steps.push({
            id: _uuid(),
            enabled: true,
            on_error: "stop",
            action: _defaultActionForKind(kind)
        })
        root.workflow = wf
        _scheduleSave()
    }

    // Drag a top-level card onto a container → reparent: pull the
    // dragged step out of the top-level sequence and append to the
    // target container's inner steps. Step.id is preserved so its
    // existing canvas position entry, when present, is cleaned up
    // (no longer top-level → no canvas card).
    function _moveStepToContainer(fromIndex, containerIndex) {
        if (fromIndex === containerIndex) return
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = _stepsAtCrumb(wf)
        if (!steps) return
        if (fromIndex < 0 || fromIndex >= steps.length) return
        if (containerIndex < 0 || containerIndex >= steps.length) return
        const containerStep = steps[containerIndex]
        const containerAction = containerStep.action
        if (!containerAction) return
        const k = containerAction.kind
        if (k !== "conditional" && k !== "repeat") return
        if (!Array.isArray(containerAction.steps)) containerAction.steps = []

        // containerStep is still a live ref into the post-splice array
        // so the push hits the right object regardless of index shift.
        const [moved] = steps.splice(fromIndex, 1)
        containerAction.steps.push(moved)

        root.workflow = wf

        if (canvasView.positions[moved.id]) {
            const next = Object.assign({}, canvasView.positions)
            delete next[moved.id]
            canvasView.positions = next
        }

        const newContainerIdx = fromIndex < containerIndex
            ? containerIndex - 1 : containerIndex
        editorContent._setSingleSelection(newContainerIdx)
        editorContent.selectedInnerIndex = containerAction.steps.length - 1

        _scheduleSave()
    }

    function _deleteInnerStep(stepIndex, innerIndex) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = _stepsAtCrumb(wf)
        if (!steps) return
        if (stepIndex < 0 || stepIndex >= steps.length) return
        const action = steps[stepIndex].action
        if (!action || !Array.isArray(action.steps)) return
        if (innerIndex < 0 || innerIndex >= action.steps.length) return
        action.steps.splice(innerIndex, 1)
        root.workflow = wf
        _scheduleSave()
    }

    function _addElseStep(stepIndex, kind) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = _stepsAtCrumb(wf)
        if (!steps) return
        if (stepIndex < 0 || stepIndex >= steps.length) return
        const action = steps[stepIndex].action
        if (!action || action.kind !== "conditional") return
        if (!Array.isArray(action.else_steps)) action.else_steps = []
        action.else_steps.push({
            id: _uuid(),
            enabled: true,
            on_error: "stop",
            action: _defaultActionForKind(kind)
        })
        root.workflow = wf
        _scheduleSave()
    }

    function _deleteElseStep(stepIndex, innerIndex) {
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = _stepsAtCrumb(wf)
        if (!steps) return
        if (stepIndex < 0 || stepIndex >= steps.length) return
        const action = steps[stepIndex].action
        if (!action || !Array.isArray(action.else_steps)) return
        if (innerIndex < 0 || innerIndex >= action.else_steps.length) return
        action.else_steps.splice(innerIndex, 1)
        root.workflow = wf
        _scheduleSave()
    }

    function _commitTitleEdit(newTitle) {
        if (newTitle === root.workflow.title) return
        const wf = JSON.parse(JSON.stringify(root.workflow))
        wf.title = newTitle
        root.workflow = wf
        _scheduleSave()
    }

    function _commitSubtitleEdit(newSubtitle) {
        if (newSubtitle === (root.workflow.subtitle || "")) return
        const wf = JSON.parse(JSON.stringify(root.workflow))
        wf.subtitle = newSubtitle
        root.workflow = wf
        _scheduleSave()
    }

    function _scheduleSave() {
        root.saveState = "dirty"
        saveTimer.restart()
    }

    function _askDelete() {
        if (!root.workflowId || root.workflowId === "new-draft") {
            root.backRequested()
            return
        }
        deleteDialog.open()
    }

    WfConfirmDialog {
        id: deleteDialog
        title: "Delete workflow?"
        message: "This permanently deletes “" + (root.title || "Untitled workflow")
            + "” from your library. The KDL file is removed from disk."
        confirmText: "Delete"
        destructive: true
        onConfirmed: {
            libCtrl.remove(root.workflowId)
            root.backRequested()
        }
    }

    ExploreController {
        id: publishCatalog
        onPublish_succeeded: (handle, slug, url) => {
            publishDialog.publishedHandle = handle
            publishDialog.publishedSlug = slug
            publishDialog.publishedUrl = url
            publishDialog.lastError = ""
            publishDialog.succeeded = true
        }
        onPublish_failed: (reason) => {
            publishDialog.lastError = reason
            publishDialog.succeeded = false
        }
        onAuth_expired: {
            Theme._auth.sign_out()
            publishDialog.lastError = "signed out, sign in again to publish"
        }
    }

    PublishDialog {
        id: publishDialog
        busy: publishCatalog.loading
        onPublishRequested: (workflowId, description, readme, tagsJson, visibility) => {
            publishCatalog.publish_workflow(
                workflowId,
                description,
                readme,
                tagsJson,
                visibility
            )
        }
    }

    function _saveNow() {
        root.saveState = "saving"
        const json = JSON.stringify(root.workflow)
        let ok
        if (root.fragmentMode) {
            const savedPath = wfCtrl.save_fragment(root.fragmentPath, json)
            ok = (savedPath && savedPath.length > 0)
        } else {
            // Bridge.save sets workflow_json which echoes back via
            // on_WorkflowJsonMirrorChanged; suppress the phantom undo entry.
            root._suppressNextMirrorUpdate = true
            const newId = wfCtrl.save(json)
            ok = (newId && newId.length > 0)
        }
        if (ok) {
            root.saveState = "saved"
            savedToast.restart()
        } else {
            root.saveState = "error"
        }
    }

    Timer { id: saveTimer; interval: 600; repeat: false; onTriggered: root._saveNow() }

    // 80-entry cap; debounced ~600ms so a typing burst is one undo entry.
    property bool _undoSkipNext: false
    property string _undoLastSnap: ""
    property double _undoLastPushAt: 0
    property var _undoStack: []
    property var _redoStack: []
    readonly property bool canUndo: _undoStack.length > 0
    readonly property bool canRedo: _redoStack.length > 0
    readonly property int _undoCap: 80
    readonly property int _undoCoalesceMs: 600

    Connections {
        target: root
        function onWorkflowChanged() {
            const cur = JSON.stringify(root.workflow)
            if (root._undoSkipNext) {
                root._undoSkipNext = false
                root._undoLastSnap = cur
                return
            }
            const prev = root._undoLastSnap
            root._undoLastSnap = cur
            if (prev.length === 0 || prev === cur) return
            const now = Date.now()
            const stack = root._undoStack.slice()
            if (now - root._undoLastPushAt < root._undoCoalesceMs && stack.length > 0) {
                // Pre-burst state already on top; skip intra-burst snap.
            } else {
                stack.push(prev)
                if (stack.length > root._undoCap) stack.shift()
                root._undoStack = stack
                root._undoLastPushAt = now
            }
            if (root._redoStack.length > 0) root._redoStack = []
        }
    }

    function _undo() {
        const stack = root._undoStack
        if (stack.length === 0) return
        const next = stack.slice()
        const snap = next.pop()
        root._undoStack = next
        const redoNext = root._redoStack.slice()
        redoNext.push(JSON.stringify(root.workflow))
        if (redoNext.length > root._undoCap) redoNext.shift()
        root._redoStack = redoNext
        // Skip recording; undo/redo never become their own entries.
        root._undoSkipNext = true
        root.workflow = JSON.parse(snap)
        editorContent._clearSelection()
        editorContent.selectedInnerIndex = -1
        _scheduleSave()
    }

    function _redo() {
        const stack = root._redoStack
        if (stack.length === 0) return
        const next = stack.slice()
        const snap = next.pop()
        root._redoStack = next
        const undoNext = root._undoStack.slice()
        undoNext.push(JSON.stringify(root.workflow))
        if (undoNext.length > root._undoCap) undoNext.shift()
        root._undoStack = undoNext
        root._undoSkipNext = true
        root.workflow = JSON.parse(snap)
        editorContent._clearSelection()
        editorContent.selectedInnerIndex = -1
        _scheduleSave()
    }

    Shortcut {
        sequence: "Ctrl+Z"
        enabled: root.visible && root.canUndo
        onActivated: root._undo()
    }
    Shortcut {
        sequence: "Ctrl+Shift+Z"
        enabled: root.visible && root.canRedo
        onActivated: root._redo()
    }
    Shortcut {
        sequence: "Ctrl+Y"
        enabled: root.visible && root.canRedo
        onActivated: root._redo()
    }
    Timer { id: savedToast; interval: 1800; repeat: false
        onTriggered: if (root.saveState === "saved") root.saveState = "idle"
    }

    // ============ Card-position persistence ============
    // Canvas card positions persist via the workflows.toml sidecar
    // (same file that already holds last_run timestamps). Keyed by
    // (workflowId, stepId). Save fires on canvas positions-change
    // (debounced 400ms); load runs after each workflow_jsonChanged.

    // One-shot guards. wfCtrl.save fires workflow_jsonChanged again
    // (cxx-qt's set_workflow_json emits on any string difference),
    // and the handler re-queues _ensureStableIds + _loadPositions
    // via Qt.callLater. Without these flags, _loadPositions could
    // run mid-drag and overwrite the user's in-memory drag with
    // stale disk values, the card would snap back to where it
    // started. Both reset on workflowId changes (new workflow load).
    property bool _stableIdsEnsured: false
    property bool _positionsLoaded: false

    function _loadPositions() {
        if (_positionsLoaded) return
        if (!root.workflowId || root.workflowId.length === 0) return
        let parsed = {}
        try {
            parsed = JSON.parse(libCtrl.load_positions(root.workflowId) || "{}")
        } catch (e) {
            return
        }
        _positionsLoaded = true
        if (parsed && Object.keys(parsed).length > 0) {
            // Merge over defaults; assignment-only would zero out
            // un-saved cards and wipe their wires.
            const merged = Object.assign({}, canvasView.positions, parsed)
            canvasView.positions = merged
        }
    }

    // Silent resave so .kdl picks up step IDs. Skips saveState /
    // saved-toast since this is a load-time upgrade, not a user save.
    function _ensureStableIds() {
        if (_stableIdsEnsured) return
        if ((!root.workflowId || root.workflowId.length === 0)
            && !root.fragmentMode) return
        const steps = (root.workflow && root.workflow.steps) || []
        if (steps.length === 0) return
        _stableIdsEnsured = true
        const json = JSON.stringify(root.workflow)
        if (root.fragmentMode) {
            wfCtrl.save_fragment(root.fragmentPath, json)
        } else {
            wfCtrl.save(json)
        }
    }

    function _savePositions() {
        if (!root.workflowId || root.workflowId.length === 0) return
        const positions = canvasView.positions || {}
        libCtrl.save_positions(root.workflowId, JSON.stringify(positions))
    }

    Timer { id: positionsSaveTimer; interval: 400; repeat: false
        onTriggered: root._savePositions()
    }

    Connections {
        target: canvasView
        function onPositionsChanged() {
            if (root.workflowId && root.workflowId.length > 0) {
                positionsSaveTimer.restart()
            }
        }
    }

    onWorkflowIdChanged: {
        _stableIdsEnsured = false
        _positionsLoaded = false
        _lastSeenDiskMtime = 0
        _reload()
    }
    onFragmentPathChanged: {
        _stableIdsEnsured = false
        _positionsLoaded = false
        _lastSeenDiskMtime = 0
        _reload()
    }
    Component.onCompleted: _reload()

    Shortcut {
        sequence: "Ctrl+Return"
        enabled: root.visible && (root.actions || []).length > 0 && !root.running
        onActivated: wfCtrl.run()
    }

    Shortcut {
        sequence: "Ctrl+S"
        enabled: root.visible && root.saveState !== "idle"
        onActivated: { saveTimer.stop(); root._saveNow() }
    }

    // Stays enabled with nothing selected so the editor claims the
    // key; otherwise a focused control swallows it.
    Shortcut {
        sequence: "Delete"
        enabled: root.visible
        onActivated: {
            if (editorContent.selectedCount > 0) root._bulkDeleteSelected()
        }
    }
    Shortcut {
        sequence: "Backspace"
        enabled: root.visible
        onActivated: {
            if (editorContent.selectedCount > 0) root._bulkDeleteSelected()
        }
    }
    Shortcut {
        sequence: "Escape"
        enabled: root.visible && editorContent.selectedCount > 0
        onActivated: editorContent._clearSelection()
    }
    Shortcut {
        sequence: "Ctrl+A"
        enabled: root.visible && (root.actions || []).length > 0
        onActivated: {
            const next = {}
            const n = (root.actions || []).length
            for (let i = 0; i < n; i++) next[i] = true
            editorContent.selectedIndices = next
            editorContent.selectedIndex = n > 0 ? n - 1 : -1
        }
    }

    // Focused TextFields claim the StandardKey first, so these only
    // fire when the canvas / step rail has focus, exactly when the
    // user means "copy this step" rather than "copy the text I'm
    // editing."
    Shortcut {
        sequence: StandardKey.Copy
        enabled: root.visible && editorContent.selectedCount > 0
        onActivated: root._copySelectionAsKdl()
    }
    Shortcut {
        sequence: StandardKey.Paste
        enabled: root.visible
        onActivated: root._pasteKdlIntoCurrent()
    }

    function _reload() {
        root.crumb = []
        if (root.fragmentMode) {
            // Bridge wraps the fragment's bare step list into a
            // synthetic workflow so canvas + inspector don't care.
            wfCtrl.load_fragment(root.fragmentPath)
            return
        }
        if (!root.workflowId) {
            root.workflow = { id: "", title: "Untitled workflow", subtitle: "", steps: [] }
            root.saveState = "idle"
            return
        }
        wfCtrl.load(root.workflowId)
    }

    // Connections + on<snake_case>Changed doesn't fire on cxx-qt's
    // auto-generated NOTIFY signals; this binding re-evaluates and
    // the on<Local>Changed handler runs reliably.
    property string _workflowJsonMirror: wfCtrl.workflow_json
    // _saveNow → wfCtrl.save() re-emits workflow_json with the round-
    // tripped form. Without the gate, the echo reassigns root.workflow
    // and the undo tracker pushes a phantom entry for the same edit.
    property bool _suppressNextMirrorUpdate: false
    on_WorkflowJsonMirrorChanged: {
        if (root._suppressNextMirrorUpdate) {
            root._suppressNextMirrorUpdate = false
            return
        }
        try {
            root.workflow = JSON.parse(_workflowJsonMirror || "{}")
        } catch (e) {
            root.workflow = { id: "", title: "Untitled workflow", subtitle: "", steps: [] }
        }
        Qt.callLater(root._ensureStableIds)
        Qt.callLater(root._loadPositions)
    }

    Connections {
        target: wfCtrl
        function onStep_started(index, step_id) {
            // Re-fires per iteration so inner rows can re-pulse on
            // every loop of a repeat.
            if (canvasView) canvasView.stepStarted(step_id || "")
        }
        function onRunningChanged() {
            if (wfCtrl.running) {
                root.stepStatuses = ({})
                root.stepStatusesById = ({})
            }
        }
        function onStep_done(index, step_id, status, message) {
            const idx = root._flatToActionsIdx(index)
            if (idx >= 0) {
                const next = Object.assign({}, root.stepStatuses)
                // A repeat container holds "error" once any leaf errored,
                // regardless of what later leaves do.
                if (!(next[idx] === "error" && status !== "error")) {
                    next[idx] = status
                    root.stepStatuses = next
                }
            }
            if (step_id && step_id.length > 0) {
                const byId = Object.assign({}, root.stepStatusesById)
                if (!(byId[step_id] === "error" && status !== "error")) {
                    byId[step_id] = status
                    root.stepStatusesById = byId
                }
            }
        }
        function onTrust_prompt_required(summary) {
            root.trustSummary = summary
            trustDialog.open()
        }
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        spacing: 0

        TopBar {
            id: tb
            width: parent.width
            title: root.title
            subtitle: root.subtitle
            // Title stays editable at any depth, it always names the
            // outermost workflow. Subtitle becomes a no-op while we're
            // inside a container; the breadcrumb takes the same row.
            // Fragment view is read-only; title and subtitle are the
            // synthesized basename, so no editing surface there.
            titleEditable: !root.fragmentMode && root.crumb.length === 0
            subtitleEditable: !root.fragmentMode
            backVisible: true
            crumbLabels: root.crumbLabels
            onBackClicked: root.backRequested()
            onTitleCommitted: (t) => root._commitTitleEdit(t)
            onSubtitleCommitted: (t) => root._commitSubtitleEdit(t)
            onCrumbClicked: (depth) => root.popCrumbTo(depth)

            // Compact save-state chip to the left of the action
            // buttons. Color tint changes per state; same chip
            // treatment as crumb / kind chips elsewhere.
            Rectangle {
                visible: root.saveState !== "idle"
                anchors.verticalCenter: parent.verticalCenter
                width: saveStateText.implicitWidth + 16
                height: 22
                radius: Theme.radiusSm
                readonly property color tint: {
                    switch (root.saveState) {
                    case "dirty":  return Theme.text3
                    case "saving": return Theme.accent
                    case "saved":  return Theme.ok
                    case "error":  return Theme.err
                    }
                    return Theme.text3
                }
                color: Qt.rgba(tint.r, tint.g, tint.b, 0.18)
                border.color: Qt.rgba(tint.r, tint.g, tint.b, 0.45)
                border.width: 1
                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                Text {
                    id: saveStateText
                    anchors.centerIn: parent
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    font.weight: Font.DemiBold
                    text: {
                        switch (root.saveState) {
                        case "dirty":  return "● unsaved"
                        case "saving": return "● saving…"
                        case "saved":  return "✓ saved"
                        case "error":  return "✗ save failed"
                        }
                        return ""
                    }
                    color: parent.tint
                }
            }

            // Unicode × instead of 🗑 emoji; the emoji glyph rendered
            // taller than its sibling buttons.
            SecondaryButton {
                visible: !root.fragmentMode
                // Same button: deletes selected steps, or the workflow
                // when nothing is selected.
                text: editorContent.selectedCount > 0
                    ? (editorContent.selectedCount === 1
                        ? "× Delete step"
                        : "× Delete " + editorContent.selectedCount + " steps")
                    : "× Delete workflow"
                onClicked: {
                    if (editorContent.selectedCount > 0) {
                        root._bulkDeleteSelected()
                    } else {
                        root._askDelete()
                    }
                }
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: editorContent.selectedCount > 0
                    ? "Delete the selected step(s). Same as the Delete key."
                    : "Delete this workflow from your library."
            }
            // Fragments inherit the parent's imports map; no button.
            SecondaryButton {
                visible: !root.fragmentMode
                text: "↳ Imports"
                                + ((root.workflow.imports
                                    && Object.keys(root.workflow.imports).length > 0)
                                   ? "  (" + Object.keys(root.workflow.imports).length + ")"
                                   : "")
                onClicked: importsDialog.open()
            }
            SecondaryButton {
                visible: !root.fragmentMode
                text: "↗ Share"
            }
            SecondaryButton {
                visible: !root.fragmentMode
                text: root.sourcePaneOpen ? "</> Source ✓" : "</> Source"
                leftPadding: 12
                rightPadding: 12
                onClicked: {
                    root.sourcePaneOpen = !root.sourcePaneOpen
                    root.sourcePaneCopyHint = ""
                }
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: "Show the live KDL source for this workflow"
            }
            SecondaryButton {
                visible: !root.fragmentMode
                    && editorContent.selectedCount >= 1
                    && !root.running
                text: "▢ Group"
                leftPadding: 12
                rightPadding: 12
                onClicked: root._addGroupAroundSelection()
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: editorContent.selectedCount > 1
                    ? "Wrap the selected steps in a group"
                    : "Drop a group rectangle on the canvas"
            }

            SecondaryButton {
                visible: !root.fragmentMode
                text: "↶"
                leftPadding: 12
                rightPadding: 12
                enabled: root.canUndo && !root.running
                onClicked: root._undo()
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: "Undo (Ctrl+Z)"
            }
            SecondaryButton {
                visible: !root.fragmentMode
                text: "↷"
                leftPadding: 12
                rightPadding: 12
                enabled: root.canRedo && !root.running
                onClicked: root._redo()
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: "Redo (Ctrl+Shift+Z)"
            }

            SecondaryButton {
                visible: !root.fragmentMode
                    && Theme._auth.state === "signed_in"
                    && !root.running
                text: "↑ Publish"
                leftPadding: 14
                rightPadding: 14
                enabled: (root.actions || []).length > 0
                onClicked: {
                    publishDialog.workflowId = root.workflowId
                    publishDialog.workflowTitle = (root.workflow && root.workflow.title) || ""
                    publishDialog.open()
                }
                ToolTip.visible: hovered
                ToolTip.delay: 400
                ToolTip.text: "Publish this workflow to wflows.io"
            }

            // Idle: Run + Debug. Debugging: Step / Continue / Stop.
            // Running: Stop only.
            PrimaryButton {
                id: runBtn
                visible: !root.fragmentMode && !root.running
                text: "▶ Run"
                leftPadding: 18
                rightPadding: 18
                enabled: (root.actions || []).length > 0
                onClicked: wfCtrl.run()
            }
            SecondaryButton {
                id: debugBtn
                visible: !root.fragmentMode && !root.running
                text: "⏯ Debug"
                leftPadding: 14
                rightPadding: 14
                enabled: (root.actions || []).length > 0
                onClicked: wfCtrl.run_debug()
            }
            SecondaryButton {
                visible: !root.fragmentMode && root.running && wfCtrl.paused
                text: "↪ Step"
                leftPadding: 14
                rightPadding: 14
                onClicked: wfCtrl.step_next()
            }
            SecondaryButton {
                visible: !root.fragmentMode && root.running && wfCtrl.paused
                text: "▶ Continue"
                leftPadding: 14
                rightPadding: 14
                onClicked: wfCtrl.continue_run()
            }
            SecondaryButton {
                visible: !root.fragmentMode && root.running
                text: "■ Stop"
                leftPadding: 14
                rightPadding: 14
                onClicked: wfCtrl.stop_run()
            }
            Text {
                visible: !root.fragmentMode && root.running && !wfCtrl.paused
                text: "⏸ Running…"
                color: Theme.text2
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                font.weight: Font.Medium
                anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
                visible: root.fragmentMode
                anchors.verticalCenter: parent.verticalCenter
                width: badgeText.implicitWidth + 24
                height: 24
                radius: 12
                color: Qt.rgba(Theme.catUse.r, Theme.catUse.g, Theme.catUse.b, 0.15)
                border.color: Qt.rgba(Theme.catUse.r, Theme.catUse.g, Theme.catUse.b, 0.45)
                border.width: 1
                Text {
                    id: badgeText
                    anchors.centerIn: parent
                    text: "↳ fragment"
                    color: Theme.catUse
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    font.weight: Font.DemiBold
                }
            }
        }

        Rectangle {
            id: errorBanner
            property bool _dismissed: false
            // Mirror so the change handler fires (cxx-qt snake_case
            // properties don't trigger function-syntax Connections).
            property string _lastErrorMirror: wfCtrl.last_error
            on_LastErrorMirrorChanged: _dismissed = false

            width: parent.width
            height: visible ? 44 : 0
            visible: !_dismissed && wfCtrl.last_error.length > 0
            color: Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.10)

            Rectangle {
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                height: 1
                color: Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.45)
            }

            Row {
                anchors.fill: parent
                anchors.leftMargin: 24
                anchors.rightMargin: 16
                spacing: 12

                Rectangle {
                    width: 22
                    height: 22
                    radius: Theme.radiusSm
                    anchors.verticalCenter: parent.verticalCenter
                    color: Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.25)
                    Text {
                        anchors.centerIn: parent
                        text: "!"
                        color: Theme.err
                        font.family: Theme.familyBody
                        font.pixelSize: 14
                        font.weight: Font.Bold
                    }
                }

                Text {
                    text: wfCtrl.last_error
                    color: Theme.err
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.Medium
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    width: parent.width - 22 - 12 - 28 - 12
                }

                Rectangle {
                    width: 24
                    height: 24
                    radius: Theme.radiusSm
                    anchors.verticalCenter: parent.verticalCenter
                    color: dismissErrArea.containsMouse
                        ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.20)
                        : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.durFast } }
                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        color: dismissErrArea.containsMouse ? Theme.err : Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: 14
                        font.weight: Font.Bold
                    }
                    MouseArea {
                        id: dismissErrArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        // Clear by setting last_error="" through the
                        // bridge, the property is read-only from QML
                        // by default but we own a setter via cxx-qt.
                        // Workaround: trigger another action that
                        // Hide client-side until next change.
                        onClicked: errorBanner._dismissed = true
                    }
                }
            }

        }

        Item {
            id: editorContent
            width: parent.width
            height: parent.height - tb.height

            // selectedIndex = anchor for shift-click range expansion.
            // selectedIndices = full set, keyed by stringified index so
            // wholesale replacement triggers QML rebindings. Keep them
            // synced through the _set/_toggle/_select helpers below.
            property int selectedIndex: -1
            property int selectedInnerIndex: -1
            property var selectedIndices: ({})
            readonly property int selectedCount:
                Object.keys(selectedIndices).length
            readonly property bool inspectorOpen:
                selectedCount === 1 && selectedIndex >= 0

            function _setSingleSelection(i) {
                selectedIndex = i
                if (i < 0) {
                    selectedIndices = ({})
                } else {
                    const next = {}
                    next[i] = true
                    selectedIndices = next
                }
            }
            function _toggleSelected(i) {
                if (i < 0) return
                const next = Object.assign({}, selectedIndices)
                if (next[i]) {
                    delete next[i]
                    if (selectedIndex === i) {
                        const remaining = Object.keys(next)
                        selectedIndex = remaining.length === 1
                            ? Number(remaining[0]) : -1
                    }
                } else {
                    next[i] = true
                    selectedIndex = i
                }
                selectedIndices = next
            }
            function _selectRange(anchor, target) {
                if (anchor < 0) {
                    _setSingleSelection(target)
                    return
                }
                const lo = Math.min(anchor, target)
                const hi = Math.max(anchor, target)
                const next = {}
                for (let i = lo; i <= hi; i++) next[i] = true
                selectedIndices = next
                selectedIndex = target
            }
            function _clearSelection() { _setSingleSelection(-1) }

            readonly property var selectedAction: {
                const list = root.actions || []
                if (selectedIndex < 0 || selectedIndex >= list.length) return null
                if (selectedInnerIndex < 0) return list[selectedIndex]
                const parent = root.workflow.steps[selectedIndex]
                if (!parent || !parent.action || !Array.isArray(parent.action.steps)) return null
                if (selectedInnerIndex >= parent.action.steps.length) return null
                return root._stepToAction(parent.action.steps[selectedInnerIndex])
            }
            readonly property var prevAction: {
                if (selectedIndex < 0) return null
                if (selectedInnerIndex >= 0) {
                    const parent = root.workflow.steps[selectedIndex]
                    if (!parent || !parent.action || !Array.isArray(parent.action.steps)) return null
                    if (selectedInnerIndex <= 0) return null
                    return root._stepToAction(parent.action.steps[selectedInnerIndex - 1])
                }
                if (selectedIndex <= 0 || (root.actions || []).length === 0) return null
                return root.actions[selectedIndex - 1]
            }
            readonly property var nextAction: {
                if (selectedIndex < 0) return null
                if (selectedInnerIndex >= 0) {
                    const parent = root.workflow.steps[selectedIndex]
                    if (!parent || !parent.action || !Array.isArray(parent.action.steps)) return null
                    if (selectedInnerIndex + 1 >= parent.action.steps.length) return null
                    return root._stepToAction(parent.action.steps[selectedInnerIndex + 1])
                }
                if (selectedIndex + 1 >= (root.actions || []).length) return null
                return root.actions[selectedIndex + 1]
            }

            // Clamps only; never auto-selects. Auto-selecting on
            // palette drops fought the deselect TapHandler and made
            // the inspector flash in/out/in.
            function _reconcileSelection() {
                const n = (root.actions || []).length
                if (n === 0) {
                    selectedIndex = -1
                    selectedInnerIndex = -1
                    return
                }
                if (selectedIndex >= n) {
                    selectedIndex = n - 1
                    selectedInnerIndex = -1
                }
                if (selectedInnerIndex >= 0) {
                    const parent = root.workflow.steps[selectedIndex]
                    const innerLen = (parent && parent.action && Array.isArray(parent.action.steps))
                        ? parent.action.steps.length : 0
                    if (selectedInnerIndex >= innerLen) {
                        selectedInnerIndex = -1
                    }
                }
            }
            Connections {
                target: root
                function onActionsChanged() { editorContent._reconcileSelection() }
            }
            Component.onCompleted: _reconcileSelection()

            EmptyState {
                anchors.fill: parent
                visible: !root.workflowId && !root.fragmentMode
                title: "No workflow loaded"
                description: "Pick one from the library, or create a new one."
                actionLabel: ""
            }

            StepListRail {
                id: rail
                visible: root.workflowId.length > 0 || root.fragmentMode
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.leftMargin: 24
                anchors.topMargin: 16
                anchors.bottomMargin: 24
                width: 280

                actions: root.actions
                activeStepIndex: root.activeStepIndex
                selectedIndex: editorContent.selectedIndex
                // Live union so rail rows highlight DURING marquee drag.
                selectedIndices: canvasView.liveSelectedIndices
                stepStatuses: root.stepStatuses

                showTutorial: _shouldShowBlankTutorial
                onTutorialDismissed: {
                    stateCtrl.mark_tutorial_seen("blank_workflow")
                    root._tutorialDismissedThisSession = true
                }

                onSelectRequested: (i) => editorContent._setSingleSelection(i)
                onRangeSelectRequested: (i) =>
                    editorContent._selectRange(editorContent.selectedIndex, i)
                onToggleSelectRequested: (i) =>
                    editorContent._toggleSelected(i)
                onAddStepRequested: (kind) => {
                    root._addStep(kind)
                    editorContent._setSingleSelection((root.actions || []).length - 1)
                }
                onDeleteStepRequested: (stepIndex) => root._deleteStep(stepIndex)
                onMoveStepRequested: (from, to) => root._moveStep(from, to)
            }

            // Width animates 0→360 so the panel arrives in place; the
            // canvas reflows because it anchors to inspectorContainer.left.
            Item {
                id: inspectorContainer
                visible: root.workflowId.length > 0 || root.fragmentMode
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.rightMargin: 24
                anchors.topMargin: 16
                anchors.bottomMargin: 24
                width: editorContent.inspectorOpen ? 360 : 0
                clip: true
                Behavior on width {
                    NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Theme.easingStd }
                }

                StepInspectorPanel {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 360
                    sel: editorContent.selectedAction
                    selectedIndex: editorContent.selectedIndex
                    totalSteps: (root.actions || []).length
                    prevAction: editorContent.prevAction
                    nextAction: editorContent.nextAction
                    allActions: root.actions
                    onValueEdited: (stepIndex, newPrimary) => root._commitStepEdit(stepIndex, newPrimary)
                    onOptionEdited: (stepIndex, path, value) => root._commitOption(stepIndex, path, value)
                    onCloseRequested: {
                        editorContent._setSingleSelection(-1)
                        editorContent.selectedInnerIndex = -1
                    }
                    onSelectStep: (i) => {
                        // Inner selection → walk siblings; otherwise
                        // walk the top-level chain.
                        if (editorContent.selectedInnerIndex >= 0) {
                            editorContent.selectedInnerIndex = i
                        } else {
                            editorContent._setSingleSelection(i)
                            editorContent.selectedInnerIndex = -1
                        }
                    }
                    onPredecessorChosen: (otherIdx) => root._makePredecessorOf(editorContent.selectedIndex, otherIdx)
                    onSuccessorChosen: (otherIdx) => root._makeSuccessorOf(editorContent.selectedIndex, otherIdx)
                    onConditionEdited: (stepIndex, cond) => root._commitCondition(stepIndex, cond)
                    onNegateToggled: (stepIndex, negate) => root._commitNegate(stepIndex, negate)
                    onInnerStepAdded: (stepIndex, kind) => root._addInnerStep(stepIndex, kind)
                    onInnerStepDeleted: (stepIndex, innerIndex) => root._deleteInnerStep(stepIndex, innerIndex)
                    onElseStepAdded: (stepIndex, kind) => root._addElseStep(stepIndex, kind)
                    onElseStepDeleted: (stepIndex, innerIndex) => root._deleteElseStep(stepIndex, innerIndex)
                }
            }

            WorkflowCanvas {
                id: canvasView
                visible: root.workflowId.length > 0 || root.fragmentMode
                anchors.left: rail.right
                anchors.right: inspectorContainer.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.leftMargin: 16
                anchors.rightMargin: editorContent.inspectorOpen ? 16 : 0
                anchors.topMargin: 16
                anchors.bottomMargin: 24
                actions: root.actions
                selectedIndex: editorContent.selectedIndex
                selectedInnerIndex: editorContent.selectedInnerIndex
                selectedIndices: editorContent.selectedIndices
                activeStepIndex: root.activeStepIndex
                activeParentIndex: root.activeParentIndex
                stepStatuses: root.stepStatuses
                stepStatusesById: root.stepStatusesById
                activeStepId: wfCtrl.active_step_id
                groups: (root.workflow && root.workflow.groups) || []
                onSelectStep: (i) => {
                    editorContent._setSingleSelection(i)
                    editorContent.selectedInnerIndex = -1
                }
                onRangeSelectStep: (i) => {
                    editorContent._selectRange(editorContent.selectedIndex, i)
                    editorContent.selectedInnerIndex = -1
                }
                onToggleSelectStep: (i) => {
                    editorContent._toggleSelected(i)
                    editorContent.selectedInnerIndex = -1
                }
                onMarqueeSelected: (set) => {
                    // Anchor on the highest index so a follow-up
                    // shift-click expands from there.
                    editorContent.selectedIndices = set
                    const keys = Object.keys(set).map(Number).sort((a, b) => b - a)
                    editorContent.selectedIndex = keys.length > 0 ? keys[0] : -1
                    editorContent.selectedInnerIndex = -1
                }
                onAddGroupRequested: (x, y, w, h) => root._addGroup(x, y, w, h)
                onMoveGroupRequested: (id, x, y) => root._moveGroup(id, x, y)
                onResizeGroupRequested: (id, x, y, w, h) =>
                    root._resizeGroup(id, x, y, w, h)
                onDeleteGroupRequested: (id) => root._deleteGroup(id)
                onEditGroupCommentRequested: (id, comment) =>
                    root._editGroupComment(id, comment)
                onEditGroupColorRequested: (id, color) =>
                    root._editGroupColor(id, color)
                onDeselectRequested: {
                    editorContent._setSingleSelection(-1)
                    editorContent.selectedInnerIndex = -1
                }
                onSelectInnerStep: (parentIdx, innerIdx) => {
                    editorContent._setSingleSelection(parentIdx)
                    editorContent.selectedInnerIndex = innerIdx
                }
                onAddStepAtRequested: (kind, x, y) => root._addStepAt(kind, x, y)
                onDeleteStepRequested: (i) => root._deleteStep(i)
                onAddInnerStepRequested: (stepIdx, kind) => root._addInnerStep(stepIdx, kind)
                onAddElseStepRequested: (stepIdx, kind) => root._addElseStep(stepIdx, kind)
                onDeleteInnerStepRequested: (stepIdx, innerIdx) => root._deleteInnerStep(stepIdx, innerIdx)
                onMoveStepToContainerRequested: (fromIdx, toIdx) => root._moveStepToContainer(fromIdx, toIdx)
                onOpenContainerRequested: (stepIdx) => root.pushCrumb(stepIdx)
                onOpenUseRequested: (stepIdx) => root._openUseImport(stepIdx)
                onOptionEdited: (stepIdx, path, value) => root._commitOption(stepIdx, path, value)
                onPredecessorChosen: (stepIdx, otherIdx) => root._makePredecessorOf(stepIdx, otherIdx)
                onSuccessorChosen: (stepIdx, otherIdx) => root._makeSuccessorOf(stepIdx, otherIdx)
                onCopyStepAsKdlRequested: (stepIdx) => root._copyMenuTarget(stepIdx)
                onPasteKdlRequested: () => root._pasteKdlIntoCurrent()
            }

            // Read-only KDL mirror of the live workflow. Slides in from
            // the right of the canvas over the inspector area, so the
            // user can keep editing on the canvas and watch the source
            // re-encode in place. Width animates 0→520.
            ViewSourcePane {
                id: sourcePane
                visible: width > 0
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.rightMargin: 24
                anchors.topMargin: 16
                anchors.bottomMargin: 24
                width: root.sourcePaneOpen ? 520 : 0
                z: 10
                clip: true

                kdlText: root.sourceKdl
                kdlSpansJson: root.sourceSpansJson
                copyHint: root.sourcePaneCopyHint

                onCloseRequested: root.sourcePaneOpen = false
                onCopyRequested: {
                    sourceClipboard.text = root.sourceKdl
                    sourceClipboard.selectAll()
                    sourceClipboard.copy()
                    sourceClipboard.deselect()
                    root.sourcePaneCopyHint = "✓ copied"
                    sourceCopyResetTimer.restart()
                }

                Behavior on width {
                    NumberAnimation {
                        duration: Theme.dur(Theme.durSlow)
                        easing.type: Theme.easingStd
                    }
                }
            }

            // Qt 6 has no QML-level Clipboard.setText; copy() on a
            // hidden TextEdit is the dependency-free path.
            TextEdit {
                id: sourceClipboard
                visible: false
                width: 0
                height: 0
            }

            Timer {
                id: sourceCopyResetTimer
                interval: 1400
                repeat: false
                onTriggered: root.sourcePaneCopyHint = ""
            }

            // External file drop, scoped to the canvas. A `.kdl` dropped
            // from a file manager parses through the same path the
            // clipboard paste uses and lands at the current crumb.
            // Disabled in fragmentMode (read-only `use` view).
            DropArea {
                id: canvasKdlDrop
                anchors.fill: canvasView
                visible: canvasView.visible && !root.fragmentMode
                enabled: visible
                z: canvasView.z + 1
                onEntered: (drag) => {
                    const urls = drag.urls || []
                    let any = false
                    for (let i = 0; i < urls.length; i++) {
                        if ((urls[i] + "").toLowerCase().endsWith(".kdl")) {
                            any = true
                            break
                        }
                    }
                    if (!any) drag.accepted = false
                }
                onDropped: (drop) => {
                    const urls = drop.urls || []
                    let imported = 0
                    for (let i = 0; i < urls.length; i++) {
                        const url = urls[i] + ""
                        if (!url.toLowerCase().endsWith(".kdl")) continue
                        const local = root._localPathFromDropUrl(url)
                        if (root._importKdlFileIntoCurrent(local)) imported++
                    }
                    if (imported > 0) drop.accept()
                }

                // Coral wash + accent border while a valid drag hovers,
                // same shape as a selected card so the affordance reads
                // as part of the existing visual language.
                Rectangle {
                    anchors.fill: parent
                    color: parent.containsDrag ? Theme.accentWash(0.18) : "transparent"
                    border.color: parent.containsDrag ? Theme.accent : "transparent"
                    border.width: parent.containsDrag ? 2 : 0
                    radius: Theme.radiusMd
                    Behavior on color { ColorAnimation { duration: Theme.durFast } }
                }
            }

            // Anchored to canvasView (not inside its Flickable) so
            // canvas pan/zoom don't move it. Centered along the top
            // edge so neither the StepPalette (left, expands on hover)
            // nor the StepInspectorPanel (right, slides in on select)
            // covers the card. Right-anchored placement got clobbered
            // by the inspector; left-anchored looked off-balance.
            Item {
                id: triggerPinned
                visible: canvasView.visible && !root.fragmentMode
                anchors.horizontalCenter: canvasView.horizontalCenter
                anchors.top: canvasView.top
                anchors.topMargin: 16
                width: triggerCard.width
                height: triggerCard.height
                z: 5

                // Trigger.kind is itself a TriggerKind tagged "kind",
                // hence the double dereference. The when block uses
                // kebab-case (TriggerCondition is rename_all kebab).
                readonly property var _firstChordTrigger: {
                    const triggers = (root.workflow && root.workflow.triggers) || []
                    for (let i = 0; i < triggers.length; ++i) {
                        const t = triggers[i]
                        if (t && t.kind && t.kind.kind === "chord" && t.kind.chord) {
                            return t
                        }
                    }
                    return null
                }
                readonly property string chord: {
                    const t = _firstChordTrigger
                    return (t && t.kind) ? (t.kind.chord || "") : ""
                }
                readonly property string whenKind: {
                    const t = _firstChordTrigger
                    if (!t || !t.when || !t.when.kind) return ""
                    return t.when.kind
                }
                readonly property string whenValue: {
                    const t = _firstChordTrigger
                    if (!t || !t.when) return ""
                    return t.when.class || t.when.title || ""
                }

                Rectangle {
                    id: triggerCard
                    width: 240
                    height: triggerLayout.implicitHeight + 24
                    radius: Theme.radiusMd
                    color: triggerArea.containsMouse ? Theme.surface2 : Theme.surface
                    border.color: triggerPinned.chord.length > 0
                        ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55)
                        : Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.3)
                    border.width: 1.5
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                    Column {
                        id: triggerLayout
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        spacing: 6

                        Row {
                            spacing: 8
                            Item {
                                width: 12; height: 12
                                anchors.verticalCenter: parent.verticalCenter
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 11; height: 11
                                    radius: 2.5
                                    color: "transparent"
                                    border.color: Theme.accent
                                    border.width: 1.3
                                }
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 5; height: 1.3
                                    color: Theme.accent
                                }
                            }
                            Text {
                                text: "TRIGGER"
                                color: Theme.accent
                                font.family: Theme.familyMono
                                font.pixelSize: 10
                                font.weight: Font.Bold
                                font.letterSpacing: 0.9
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        Text {
                            text: triggerPinned.chord.length > 0
                                ? triggerPinned.chord
                                : "+ Bind a chord"
                            color: triggerPinned.chord.length > 0
                                ? Theme.text
                                : Theme.accent
                            font.family: Theme.familyMono
                            font.pixelSize: triggerPinned.chord.length > 0
                                ? Theme.fontMd
                                : Theme.fontSm
                            font.weight: Font.DemiBold
                            font.letterSpacing: 0.4
                            elide: Text.ElideRight
                            width: parent.width
                        }

                        Text {
                            visible: triggerPinned.chord.length > 0 && triggerPinned.whenKind.length > 0
                            text: {
                                const k = triggerPinned.whenKind
                                const v = triggerPinned.whenValue
                                const verb = k === "window-class"
                                    ? "when window class is"
                                    : "when window title contains"
                                return verb + " " + v
                            }
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontXs
                            elide: Text.ElideRight
                            width: parent.width
                        }
                    }

                    MouseArea {
                        id: triggerArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            triggerCardChordDialog.initialChord = triggerPinned.chord
                            triggerCardChordDialog.initialWhenKind = triggerPinned.whenKind
                            triggerCardChordDialog.initialWhenValue = triggerPinned.whenValue
                            triggerCardChordDialog.open()
                        }
                    }

                    // Inline unbind so it isn't buried two clicks deep
                    // inside the chord dialog. z above triggerArea so
                    // hover and click don't fall through to the card.
                    Rectangle {
                        id: triggerUnbindBtn
                        visible: triggerPinned.chord.length > 0
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.topMargin: 8
                        anchors.rightMargin: 8
                        width: 18
                        height: 18
                        radius: 9
                        z: 1
                        color: triggerUnbindArea.containsMouse
                            ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.18)
                            : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                        Text {
                            anchors.centerIn: parent
                            text: "×"
                            color: triggerUnbindArea.containsMouse ? Theme.err : Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: 14
                            font.weight: Font.Medium
                        }

                        MouseArea {
                            id: triggerUnbindArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            ToolTip.visible: containsMouse
                            ToolTip.delay: 400
                            ToolTip.text: "Unbind chord"
                            onClicked: {
                                if (root.workflowId.length > 0) {
                                    libCtrl.set_chord(root.workflowId, "", "", "")
                                    wfCtrl.load(root.workflowId)
                                }
                            }
                        }
                    }
                }

                ChordCaptureDialog {
                    id: triggerCardChordDialog
                    onCaptured: (chord, whenKind, whenValue) => {
                        if (root.workflowId.length > 0) {
                            libCtrl.set_chord(root.workflowId, chord, whenKind, whenValue)
                            wfCtrl.load(root.workflowId)
                        }
                    }
                    onCleared: {
                        if (root.workflowId.length > 0) {
                            libCtrl.set_chord(root.workflowId, "", "", "")
                            wfCtrl.load(root.workflowId)
                        }
                    }
                }
            }

            StepPalette {
                id: paletteDockInst
                visible: root.workflowId.length > 0 || root.fragmentMode
                anchors.left: canvasView.left
                anchors.verticalCenter: canvasView.verticalCenter
                anchors.leftMargin: 12
                z: 60
                canvas: canvasView
            }
        }
    }

    Dialog {
        id: importsDialog
        parent: Overlay.overlay
        modal: true
        title: ""

        width: Math.min(640, parent ? parent.width * 0.9 : 640)
        height: Math.min(560, parent ? parent.height * 0.85 : 560)
        anchors.centerIn: parent

        background: Rectangle {
            color: Theme.surface
            radius: Theme.radiusMd
            border.color: Theme.line
            border.width: 1
        }

        readonly property var importNames: root.workflow && root.workflow.imports
            ? Object.keys(root.workflow.imports).sort()
            : []

        contentItem: Item {
            anchors.fill: parent
            Column {
                anchors.fill: parent
                anchors.margins: 24
                spacing: 16

                Column {
                    width: parent.width
                    spacing: 4
                    Text {
                        text: "Workflow imports"
                        color: Theme.text
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontXl
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: "Map a short name to a .kdl fragment path. `use NAME` steps splice the fragment in at decode time."
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                        width: parent.width
                        lineHeight: 1.4
                    }
                }

                ScrollView {
                    width: parent.width
                    height: parent.height - parent.spacing * 2 - 80 - 56
                    clip: true

                    Column {
                        width: parent.parent.width
                        spacing: 6

                        Repeater {
                            model: importsDialog.importNames
                            delegate: Rectangle {
                                width: parent.width
                                height: 44
                                radius: Theme.radiusMd
                                color: Theme.bg
                                border.color: Theme.lineSoft
                                border.width: 1

                                readonly property string importName: modelData
                                readonly property string importPath:
                                    (root.workflow.imports && root.workflow.imports[importName]) || ""

                                Row {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 6
                                    spacing: 8

                                    TextField {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 130
                                        text: parent.parent.importName
                                        color: Theme.text
                                        font.family: Theme.familyMono
                                        font.pixelSize: Theme.fontSm
                                        background: Rectangle {
                                            color: Theme.surface2
                                            radius: 4
                                            border.color: Theme.lineSoft
                                            border.width: 1
                                        }
                                        onEditingFinished: root._renameImport(parent.parent.importName, text)
                                    }

                                    TextField {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - 130 - 28 - 8 * 2
                                        text: parent.parent.importPath
                                        placeholderText: "fragments/foo.kdl"
                                        color: Theme.text
                                        font.family: Theme.familyMono
                                        font.pixelSize: Theme.fontSm
                                        background: Rectangle {
                                            color: Theme.surface2
                                            radius: 4
                                            border.color: Theme.lineSoft
                                            border.width: 1
                                        }
                                        onEditingFinished: root._setImport(parent.parent.importName, text)
                                    }

                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 28; height: 28; radius: 4
                                        color: importDelArea.containsMouse
                                            ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.18)
                                            : "transparent"
                                        Text {
                                            anchors.centerIn: parent
                                            text: "×"
                                            color: importDelArea.containsMouse ? Theme.err : Theme.text2
                                            font.family: Theme.familyBody
                                            font.pixelSize: 16
                                        }
                                        MouseArea {
                                            id: importDelArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root._deleteImport(parent.parent.parent.importName)
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            visible: importsDialog.importNames.length === 0
                            text: "No imports yet. Add one below to use it from `use NAME` steps."
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            font.italic: true
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            topPadding: 24
                            bottomPadding: 24
                        }
                    }
                }

                Row {
                    width: parent.width
                    spacing: 8

                    TextField {
                        id: newImportName
                        width: 130
                        placeholderText: "name"
                        color: Theme.text
                        font.family: Theme.familyMono
                        font.pixelSize: Theme.fontSm
                        background: Rectangle {
                            color: Theme.surface2
                            radius: 4
                            border.color: Theme.lineSoft
                            border.width: 1
                        }
                    }
                    TextField {
                        id: newImportPath
                        width: parent.width - 130 - 80 - 8 * 2
                        placeholderText: "fragments/foo.kdl"
                        color: Theme.text
                        font.family: Theme.familyMono
                        font.pixelSize: Theme.fontSm
                        background: Rectangle {
                            color: Theme.surface2
                            radius: 4
                            border.color: Theme.lineSoft
                            border.width: 1
                        }
                    }
                    PrimaryButton {
                        text: "+ Add"
                        enabled: newImportName.text.length > 0 && newImportPath.text.length > 0
                        onClicked: {
                            root._setImport(newImportName.text, newImportPath.text)
                            newImportName.text = ""
                            newImportPath.text = ""
                        }
                    }
                }

                Row {
                    width: parent.width
                    layoutDirection: Qt.RightToLeft
                    SecondaryButton {
                        text: "Done"
                        onClicked: importsDialog.close()
                    }
                }
            }
        }
    }

    // Engine waits for confirm_trust() / cancel_trust() before running.
    // Mirrors the CLI prompt body (src/security.rs).
    Dialog {
        id: trustDialog
        parent: Overlay.overlay
        modal: true
        closePolicy: Popup.NoAutoClose
        title: ""

        width: Math.min(640, parent ? parent.width * 0.9 : 640)
        height: Math.min(560, parent ? parent.height * 0.85 : 560)
        anchors.centerIn: parent

        background: Rectangle {
            color: Theme.surface
            radius: Theme.radiusMd
            border.color: Theme.line
            border.width: 1
        }

        contentItem: Item {
            anchors.fill: parent

            Column {
                anchors.fill: parent
                anchors.margins: 24
                spacing: 16

                Column {
                    width: parent.width
                    spacing: 6

                    Row {
                        spacing: 10
                        Rectangle {
                            width: 28; height: 28; radius: 14
                            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                            border.color: Theme.accent
                            border.width: 1
                            anchors.verticalCenter: parent.verticalCenter
                            Text {
                                anchors.centerIn: parent
                                text: "!"
                                color: Theme.accent
                                font.family: Theme.familyBody
                                font.pixelSize: 16
                                font.weight: Font.Bold
                            }
                        }
                        Text {
                            text: "Run this workflow?"
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontXl
                            font.weight: Font.DemiBold
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Text {
                        text: "This workflow file hasn't run on this machine before. Review what it will execute before confirming. (See REVIEW.md for the trust model.)"
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                        width: parent.width
                        lineHeight: 1.4
                    }
                }

                ScrollView {
                    width: parent.width
                    height: parent.height - parent.spacing * 2 - 80 - 56
                    clip: true

                    Text {
                        text: root.trustSummary
                        color: Theme.text2
                        font.family: Theme.familyMono
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.NoWrap
                        textFormat: Text.PlainText
                    }
                }

                Row {
                    width: parent.width
                    spacing: 8
                    layoutDirection: Qt.RightToLeft

                    PrimaryButton {
                        text: "Confirm and run"
                        onClicked: {
                            trustDialog.close()
                            wfCtrl.confirm_trust()
                        }
                    }
                    SecondaryButton {
                        text: "Cancel"
                        onClicked: {
                            trustDialog.close()
                            wfCtrl.cancel_trust()
                        }
                    }
                }
            }
        }
    }
}
