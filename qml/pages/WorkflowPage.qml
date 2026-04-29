import QtQuick
import QtQuick.Controls
import Wflow

// Workflow editor.
//
// Data flows through WorkflowController: we load(id) on mount, decode the
// returned JSON for the title / steps, and call run() to fire the real
// engine on the Rust side. Step progress streams back via the
// active_step property and step_done / run_finished signals.
//
// Edits to a step's primary value (value TextField in SplitInspector) bubble
// back up via `valueEdited(stepIndex, newPrimary)`. We patch the local
// `workflow` object, debounce-save through `wfCtrl.save(JSON)` (~600ms after
// the last keystroke), and show a small "saving / saved" indicator in the
// top bar.
Item {
    id: root
    property string workflowId: ""
    // Alternate load source: when set, the page loads a fragment
    // file from disk instead of looking up a workflow by id, and
    // renders in read-only mode. Set by the multi-doc tab strip
    // when the user clicks "→ open" on a `use NAME` card.
    property string fragmentPath: ""
    readonly property bool fragmentMode: fragmentPath.length > 0

    // Exposed so the first-run TutorialCoach can point at specific
    // editor regions — canvas, palette, inspector, run button —
    // when the editor section of the tour fires.
    property alias canvasArea: canvasView
    property alias paletteDock: paletteDockInst
    property alias inspectorPanel: inspectorContainer
    property alias runButton: runBtn
    property alias stepRail: rail

    signal backRequested()
    // Fired when the user clicks "→ open" on a `use NAME` card.
    // Carries the resolved absolute path and the import name (used
    // as the tab title fallback). Routed up to Main.qml which adds
    // a fragment doc to openDocs.
    signal openFragmentRequested(string path, string displayName)

    WorkflowController { id: wfCtrl }
    // Owns the blank-workflow tutorial dismissal flag (and the
    // future tutorials map). Shared across pages but always reads
    // state.toml on construction, so per-page instantiation is safe.
    StateController { id: stateCtrl }
    // Per-page LibraryController instance is fine — store::delete is
    // a filesystem op, no shared state to race on. Used by the
    // editor's Delete-workflow flow.
    LibraryController { id: libCtrl }

    // Decoded workflow object. Kept as a local property so the editor can
    // present placeholder text before load() returns AND so in-flight edits
    // have a live target to mutate.
    property var workflow: ({
        id: "",
        title: "Untitled workflow",
        subtitle: "",
        steps: []
    })

    // Save state lifecycle: "idle" → "dirty" (user edited) → "saving" →
    // "saved" (briefly, then back to idle) or "error" on save failure.
    property string saveState: "idle"

    // Per-step outcomes from the last run — { [stepIndex]: "ok"|"skipped"|"error" }.
    // Populated by the bridge's step_done signal; cleared when a new run starts.
    property var stepStatuses: ({})
    // Same outcomes keyed by the engine's stable step_id, used to
    // attach status dots to canvas inner steps that don't have a
    // top-level card (repeat children). The flat-index `stepStatuses`
    // map is still authoritative for top-level cards because it
    // aggregates repeat-leaf outcomes onto the container.
    property var stepStatusesById: ({})

    // Pending trust-prompt body. Populated when wfCtrl emits
    // `trust_prompt_required(summary)`; trustDialog reads it.
    property string trustSummary: ""

    // True while the blank-workflow tutorial is being shown. Once the
    // user dismisses (or auto-dismiss fires), we don't re-show it
    // even if the user undoes/clears all steps in the same session.
    // The disk flag (state.toml `tutorials.blank_workflow_seen`) is
    // the long-term memory; this is just session pacing.
    property bool _tutorialDismissedThisSession: false
    readonly property bool _shouldShowBlankTutorial:
        root.workflowId.length > 0
        && (root.workflow.steps || []).length === 0
        && !root._tutorialDismissedThisSession
        && !stateCtrl.tutorial_seen("blank_workflow")

    readonly property string title:    workflow.title || "Untitled workflow"
    readonly property string subtitle: workflow.subtitle || ""
    // The runner reports StepStart/StepDone with a flat leaf-only
    // index — containers (repeat) and branches (conditional) don't
    // emit events themselves; only the leaves inside do. Translate
    // that flat index back to a position in the canvas `actions`
    // array so the active-step pulse and status dots land on the
    // right cards. Conditional inner steps surface as their own
    // cards (so the leaf maps directly to the inner card); repeat
    // leaves all map to the repeat container card (it still owns
    // the inline strip).
    // Active card index, derived by matching the engine's
    // active_step_id against the shaped actions array. ID matching
    // is robust against falsy conditionals (where the engine skips
    // inner steps but the QML mapping would otherwise miscount the
    // flat index) and against note-filtering. The flat-index path
    // _flatToActionsIdx still exists for code that needs it but
    // isn't used here.
    readonly property int activeStepIndex: {
        const id = wfCtrl.active_step_id || ""
        if (id.length === 0) return -1
        const arr = root.actions || []
        for (let i = 0; i < arr.length; i++) {
            if (arr[i] && arr[i].id === id) return i
        }
        return -1
    }
    // When an inner step of a conditional is running, also light up
    // the parent conditional card. Engine doesn't emit StepStart for
    // the conditional itself — it just descends into inner steps —
    // so without this the conditional card sits dark while its
    // contents fire.
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
                // Inner steps of a conditional surface as their own
                // canvas cards. Walk inner leaves and map to the
                // matching inner card's actions index.
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
            // Repeat: still a container; the repeat card aggregates
            // all of its leaves' status. Plain leaf: 1:1.
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

    // Breadcrumb path into the workflow tree. Each entry is an index
    // into the step list at the previous depth: `[]` is the top
    // level, `[3]` is the inner step list of `wf.steps[3]` (a
    // when/unless/repeat container), `[3, 1]` is the inner list of
    // its second inner step, and so on. The canvas always renders
    // _currentSteps, never wf.steps directly.
    property var crumb: []

    // Walk the workflow according to crumb. Returns the steps array
    // at that depth, or null if any index is out of range or the
    // step at that index isn't a container. Pure read helper —
    // mutators take `wf` and walk it themselves so the result is a
    // live reference into their own clone.
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

    // The step list currently being shown in the canvas. Empty array
    // when the crumb points into a non-container (defensive — should
    // never happen if crumb mutators only push container indices).
    readonly property var _currentSteps: _stepsAtCrumb(workflow) || []

    // Breadcrumb chip labels — workflow title plus a short summary
    // for each container we've descended into. Bound reactively so
    // editing a condition in the inspector updates the crumb chip.
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
        // Only descend into a flow-control container; ignore otherwise.
        const steps = root._currentSteps
        if (stepIndex < 0 || stepIndex >= steps.length) return
        const action = steps[stepIndex].action
        if (!action) return
        if (action.kind !== "repeat" && action.kind !== "conditional") return
        root.crumb = root.crumb.concat([stepIndex])
        editorContent._setSingleSelection(-1)
        editorContent.selectedInnerIndex = -1
        // Center the viewport on the new content. The actions
        // binding has just changed and _placeNewSteps will seed
        // default positions for the inner cards on the next tick;
        // _zoomToFit then fits them to the viewport so the user
        // doesn't land on empty canvas and have to pan to find them.
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
        // Shape the Rust-side Step[] into the { kind, summary, value,
        // rawPrimary, editable } that the canvas delegates expect.
        // Driven by the crumb: at top level this is wf.steps; inside
        // a container, it's the inner step list at that depth.
        //
        // Conditionals (when/unless) are NOT containers in the visual
        // model — they're branch decision points. Their inner steps
        // surface as additional cards alongside the conditional, with
        // the canvas drawing fork/rejoin wires. Each shaped action
        // carries display metadata (_displayKind, _topIdx, _innerIdx,
        // _parentTopIdx) the canvas reads for layout + wire routing.
        const out = []
        const steps = root._currentSteps
        for (let i = 0; i < steps.length; i++) {
            const step = steps[i]
            // Notes (step.action.kind === "note") used to render as
            // soft annotation cards on the canvas. Group rectangles
            // do that job better now, so notes are filtered out of
            // the visual model entirely. The data round-trips
            // through KDL unchanged — old workflows with notes load
            // and re-save without losing them — but the canvas, the
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
            // model — it's a loop, not a branch.
            if (step.action && step.action.kind === "conditional") {
                const inner = step.action.steps || []
                for (let j = 0; j < inner.length; j++) {
                    if (inner[j] && inner[j].action
                        && inner[j].action.kind === "note") continue
                    const innerShaped = root._stepToAction(inner[j])
                    innerShaped._displayKind = "inner"
                    innerShaped._topIdx = -1
                    innerShaped._innerIdx = j
                    innerShaped._parentTopIdx = i
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
        // Flow-control. Repeat / use have a single primary value that
        // the inspector field can edit directly. Conditional (when /
        // unless) carries multi-field state (cond.kind + name/path/
        // equals) which needs a richer editor; primary stays read-only
        // and the inspector falls back to the cond summary for now.
        case "repeat":      shaped = { kind: "repeat",  summary: "Repeat", value: act.count + "×, " + (act.steps || []).length + " inner step(s)", rawPrimary: String(act.count), editable: true, intOnly: true, unit: "×" }; break
        case "conditional": shaped = { kind: act.negate ? "unless" : "when", summary: act.negate ? "Unless" : "When", value: _condSummary(act.cond) + ", " + (act.steps || []).length + " inner step(s)", rawPrimary: "", editable: false }; break
        case "use":         shaped = { kind: "use",     summary: "Use import", value: act.name, rawPrimary: act.name, editable: true }; break
        default:                    shaped = { kind: "note", summary: kind, value: "", rawPrimary: "", editable: false }
        }
        // Expose the raw Step + Action so the inspector can bind option editors
        // (disabled, on-error, delay-ms, clear-modifiers, retries, backoff-ms,
        // timeout-ms) directly to their canonical fields.
        shaped.id = step.id || ""
        shaped.rawKind = kind
        shaped.enabled = step.enabled !== false
        shaped.onError = step.on_error || "stop"
        shaped.rawAction = act
        // Per-step comment (separate from the action's primary value
        // — see `Step.note` in actions.rs). Surfaced in the inspector
        // as the Comment field, rendered as an italic subline on
        // each canvas card when non-empty.
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

    // Return a clone of `oldAction` with its primary value replaced.
    // Kind-aware so a `delay` step turns "500" into {ms: 500} rather than
    // shoving a string into the ms field. Non-mutable kinds pass the old
    // action through unchanged.
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
        default: return oldAction
        }
        return out
    }

    // Apply a per-step option edit. `path` is one of:
    //   "enabled"           — bool
    //   "on_error"          — "stop" | "continue"
    //   "action.<field>"    — kind-specific action field (delay_ms,
    //                         clear_modifiers, retries, backoff_ms, timeout_ms)
    // A null / empty value on an Option<T> action field deletes the key so
    // the serde default kicks in on round-trip.
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
            // Per-step comment. Empty string clears the field so
            // serde drops it on round-trip and the encoded KDL
            // doesn't carry a stray `note=""`.
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
        // RFC-4122 v4-ish; good enough for a local step id. The Rust side
        // doesn't validate UUID shape, only that `id` is a unique string.
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
        // Flow-control defaults. Conditions default to a window
        // predicate (most common opening); repeat defaults to a
        // 2-iteration empty block; use starts blank for the user to
        // fill in with an import name.
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

    // Add a step from a palette drop. Like _addStep but seeds the
    // canvas's positions map so the new card lands where the user
    // dropped it, AND clears the auto-selection so the inspector
    // doesn't slide in and shove the canvas around mid-drop.
    //
    // Position is written BEFORE the workflow mutation. Otherwise
    // _placeNewSteps fires synchronously on the actions-changed
    // signal, sees no entry for the new id, and assigns it a
    // stack-below position; the user's drop coordinate then
    // overwrites that and the cardItem animates away from origin
    // and back to the drop spot.
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
        // Pre-seed the position so _placeNewSteps skips this id.
        const next = Object.assign({}, canvasView.positions)
        next[id] = { x: Math.max(0, x), y: Math.max(0, y) }
        canvasView.positions = next
        // Intentionally NO selectedIndex change — the user dropped
        // the card to place it, not to immediately edit it.
        root.workflow = wf
        _scheduleSave()
    }

    function _deleteStep(stepIndex) {
        // The canvas emits a flat-actions index (its Repeater's model
        // is root.actions, where a conditional's inner steps surface
        // as siblings). Pick the right tree-array branch off the
        // metadata before splicing — using stepIndex directly against
        // _stepsAtCrumb would delete the wrong step the moment a
        // conditional appears in the workflow.
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
            const innerSteps = parent && parent.action ? parent.action.steps : null
            if (!Array.isArray(innerSteps)) return
            if (innerIdx < 0 || innerIdx >= innerSteps.length) return
            innerSteps.splice(innerIdx, 1)
        } else {
            const i = meta._topIdx
            if (i < 0 || i >= steps.length) return
            steps.splice(i, 1)
        }

        root.workflow = wf
        // Keep selection valid: clamp into range, or collapse the
        // inspector when no steps remain.
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
    // Groups are decorative annotations on the canvas — coloured
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
        // Bounding box of currently-selected cards, padded so the
        // group breathes around them. If nothing's selected, drop a
        // default-sized group near the viewport center.
        const selected = Object.keys(editorContent.selectedIndices).map(Number)
        if (selected.length === 0) {
            // Fallback — center on the viewport. canvasView's
            // contentX / contentY aren't exposed; use a fixed offset.
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

    // Delete every index in editorContent.selectedIndices in one
    // pass. Iterate descending so each splice doesn't invalidate the
    // indices we haven't processed yet (deleting flat index 7 leaves
    // indices 0..6 unchanged; flat index 5's metadata still resolves
    // to the same tree node).
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

    // Make the step at otherIdx the immediate predecessor of the
    // step at stepIdx. Used by both the inspector's prev/next swap
    // and the canvas's per-card rewire menu, so it takes the target
    // index explicitly rather than reading editorContent.selectedIndex.
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

    function _moveStep(from, to) {
        if (from === to) return
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = _stepsAtCrumb(wf)
        if (!steps) return
        if (from < 0 || from >= steps.length) return
        if (to < 0 || to >= steps.length) return
        const [moved] = steps.splice(from, 1)
        steps.splice(to, 0, moved)
        root.workflow = wf
        // Follow the moved step so the inspector keeps looking at
        // the same action the user just reordered.
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

    // Resolve the step being edited from a (parent, inner) pair. If
    // selectedInnerIndex is < 0, returns the top-level step; otherwise
    // walks into the parent's action.steps[innerIndex]. Returns null
    // if either coordinate is out of range.
    function _resolveStep(steps, stepIndex) {
        if (stepIndex < 0 || stepIndex >= steps.length) return null
        const inner = editorContent.selectedInnerIndex
        if (inner < 0) return steps[stepIndex]
        const parent = steps[stepIndex]
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

    // Workflow-level imports: name → path mapping. Mutators clone
    // the workflow, edit the imports map, and trigger _scheduleSave.
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

    // Replace the cond object on a `when` / `unless` step. Pass-through
    // for the inspector's condition editor.
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

    // User clicked "→ open import" on a `use NAME` card. Look up
    // NAME in the workflow's imports map, resolve to an absolute
    // path (relative paths are relative to the workflow file's
    // directory; the bridge handles that), and signal up so Main
    // can open a fragment tab.
    function _openUseImport(stepIndex) {
        // The canvas's stepIdx is an index into root.actions, which
        // since the conditional-as-branch refactor includes both
        // top-level and inner-of-conditional cards. Reading from
        // _currentSteps (the data tree at crumb depth) skipped the
        // inner steps — opening "→ open import" on a `use` card
        // inside a conditional did nothing. Use the shaped action's
        // rawAction directly.
        const acts = root.actions || []
        if (stepIndex < 0 || stepIndex >= acts.length) return
        const act = acts[stepIndex]
        if (!act || act.rawKind !== "use") return
        const name = (act.rawAction && act.rawAction.name) || ""
        if (name.length === 0) return
        const abs = wfCtrl.resolve_import_path(name) || ""
        if (abs.length === 0) {
            // Name isn't in the imports map or the path didn't
            // resolve. Future: surface a proper error toast.
            return
        }
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

    // Append an inner step of `kind` to a flow-control container's
    // step list. Used by the inspector's "+ Add inner step" button.
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

        // Remove from the current view's step list. containerStep is
        // still a live reference into the post-splice array so the
        // push lands on the right object regardless of index shift.
        const [moved] = steps.splice(fromIndex, 1)
        containerAction.steps.push(moved)

        root.workflow = wf

        // Drop the now-orphan canvas position entry — the step is
        // no longer a top-level cardItem and won't render as one.
        if (canvasView.positions[moved.id]) {
            const next = Object.assign({}, canvasView.positions)
            delete next[moved.id]
            canvasView.positions = next
        }

        // Resolve selection: select the container in its new index,
        // and focus the newly-arrived inner step.
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
        // No-op for new-draft workflows that haven't been saved yet:
        // there's nothing on disk to delete; just navigate back.
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

    function _saveNow() {
        root.saveState = "saving"
        const json = JSON.stringify(root.workflow)
        let ok
        if (root.fragmentMode) {
            // Fragments save just their step list back to the file
            // they were loaded from — no workflow wrapper, no
            // imports map. The bridge handles the encode + atomic
            // rename.
            const savedPath = wfCtrl.save_fragment(root.fragmentPath, json)
            ok = (savedPath && savedPath.length > 0)
        } else {
            // Bridge.save sets workflow_json with the round-tripped
            // form, which echoes back to on_WorkflowJsonMirrorChanged.
            // Suppress the echo so the undo tracker doesn't push a
            // phantom snapshot for an edit that was already recorded.
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

    // ---- Undo / redo ----
    //
    // Watches root.workflow for changes and pushes the PREVIOUS
    // snapshot onto the undo stack. _undoSkipNext lets the undo /
    // redo helpers themselves apply a workflow without
    // re-recording the change as a fresh edit (which would corrupt
    // the stack). Stack caps at 80 entries — past that we drop the
    // oldest.
    //
    // Coalesces rapid edits (typing in the inspector) into a single
    // undoable entry by debouncing: pushes only once per ~600 ms
    // burst. Below that threshold the snapshots are merged into the
    // most recent stack entry.
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
            // Coalesce bursts. If the previous push was within
            // _undoCoalesceMs, drop it and replace with the new
            // 'before-burst' state. Otherwise push fresh.
            const stack = root._undoStack.slice()
            if (now - root._undoLastPushAt < root._undoCoalesceMs && stack.length > 0) {
                // The most-recent entry already represents the
                // pre-burst state. Don't overwrite it; just skip
                // pushing the intra-burst snapshot.
            } else {
                stack.push(prev)
                if (stack.length > root._undoCap) stack.shift()
                root._undoStack = stack
                root._undoLastPushAt = now
            }
            // Any forward edit invalidates redo.
            if (root._redoStack.length > 0) root._redoStack = []
        }
    }

    function _undo() {
        const stack = root._undoStack
        if (stack.length === 0) return
        const next = stack.slice()
        const snap = next.pop()
        root._undoStack = next
        // Push current onto redo.
        const redoNext = root._redoStack.slice()
        redoNext.push(JSON.stringify(root.workflow))
        if (redoNext.length > root._undoCap) redoNext.shift()
        root._redoStack = redoNext
        // Apply without recording. Undo / redo never become their
        // own undo entries.
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
    // Some users coming from Windows expect Ctrl+Y for redo.
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
    // stale disk values — the card would snap back to where it
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
            // Merge saved positions over the canvas's default
            // placements. Without the merge, cards without a saved
            // entry would lose their default position too, ending up
            // at (0, 0) — which also wipes wires whose source or
            // target lookup misses.
            const merged = Object.assign({}, canvasView.positions, parsed)
            canvasView.positions = merged
        }
    }

    // Silent resave so the .kdl file picks up `_id` properties for
    // every step. Bypasses _saveNow so saveState / the saved-toast
    // don't fire — this is a load-time upgrade, not a user save.
    function _ensureStableIds() {
        if (_stableIdsEnsured) return
        // Two valid load sources: a workflow id (real workflow) or
        // a fragmentPath (fragment view). Bail if neither.
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
        _reload()
    }
    onFragmentPathChanged: {
        _stableIdsEnsured = false
        _positionsLoaded = false
        _reload()
    }
    Component.onCompleted: _reload()

    // Run on Ctrl+Enter — the editor is the only page where this is active,
    // and the enabled guard matches the Run button.
    Shortcut {
        sequence: "Ctrl+Return"
        enabled: root.visible && (root.actions || []).length > 0 && !root.running
        onActivated: wfCtrl.run()
    }

    // Save explicitly on Ctrl+S (in case the user likes the shortcut). Still
    // debounce-saves automatically.
    Shortcut {
        sequence: "Ctrl+S"
        enabled: root.visible && root.saveState !== "idle"
        onActivated: { saveTimer.stop(); root._saveNow() }
    }

    // Delete the current selection. Single-select still works through
    // the same code path; multi-select bulk deletes from the highest
    // index down so each splice doesn't shift the indices the loop
    // hasn't visited yet.
    //
    // Stays enabled even with nothing selected so Delete is silently
    // CLAIMED by the editor — otherwise it falls through to the
    // global key chain and a focused control or system handler fires
    // its own Delete action. The 'delete this workflow' button is in
    // the top bar (clearly labelled); the Delete key only ever
    // operates on canvas selection.
    Shortcut {
        sequence: "Delete"
        enabled: root.visible
        onActivated: {
            if (editorContent.selectedCount > 0) root._bulkDeleteSelected()
        }
    }
    // Backspace as the second key for the same action — folks coming
    // from macOS hit Backspace, folks on tiling Linux setups hit
    // Delete. Both work.
    Shortcut {
        sequence: "Backspace"
        enabled: root.visible
        onActivated: {
            if (editorContent.selectedCount > 0) root._bulkDeleteSelected()
        }
    }
    // Esc clears the selection (single or multi).
    Shortcut {
        sequence: "Escape"
        enabled: root.visible && editorContent.selectedCount > 0
        onActivated: editorContent._clearSelection()
    }
    // Ctrl+A selects every step at the current crumb depth.
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

    function _reload() {
        // Loading a different document always returns to the top of
        // the tree — the previous workflow's container path is
        // meaningless against the new step list.
        root.crumb = []
        if (root.fragmentMode) {
            // Fragment mode: load by absolute path. Bridge wraps the
            // fragment's bare step list into a synthetic workflow so
            // the rest of the page (canvas, inspector) doesn't have
            // to know the difference.
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

    // Mirror wfCtrl.workflow_json into a local property so we can
    // hook a known-good QML property-change handler. Connections +
    // `function on<Property>Changed()` doesn't fire for cxx-qt's
    // auto-generated NOTIFY signals on snake_case properties; the
    // property-binding path here re-evaluates whenever the bridge
    // updates workflow_json, and the on<Local>Changed handler runs
    // reliably.
    property string _workflowJsonMirror: wfCtrl.workflow_json
    // Set true by _saveNow before it calls wfCtrl.save(...). The
    // bridge's save() re-emits workflow_json with the round-tripped
    // serialization, which lands here as a no-op echo of the same
    // workflow we just saved — but if we let it through, root.workflow
    // gets reassigned, workflowChanged fires, and the undo tracker
    // pushes a phantom snapshot for an edit that was already
    // recorded. Skipping the next mirror update breaks that loop.
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
            // Forward to canvas so inner step rows can re-trigger
            // their pulse on every iteration of a repeat.
            if (canvasView) canvasView.stepStarted(step_id || "")
        }
        function onRunningChanged() {
            // Clear previous statuses at the start of a fresh run so stale
            // glyphs from the last run don't bleed into the new one.
            if (wfCtrl.running) {
                root.stepStatuses = ({})
                root.stepStatusesById = ({})
            }
        }
        function onStep_done(index, step_id, status, message) {
            // Translate the flat leaf index to the actions array
            // index — for conditional inner steps that's the inner
            // card; for repeat leaves it's the repeat container; for
            // plain top-level leaves it's the top card.
            const idx = root._flatToActionsIdx(index)
            if (idx >= 0) {
                const next = Object.assign({}, root.stepStatuses)
                // Don't downgrade an existing "error" on a repeat
                // container — if any leaf inside errored, the container
                // shows error regardless of what later leaves did.
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
        anchors.fill: parent
        spacing: 0

        TopBar {
            id: tb
            width: parent.width
            title: root.title
            subtitle: root.subtitle
            // Title stays editable at any depth — it always names the
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

            // Direct Delete button. Was a kebab → Delete two-click
            // pattern but for the only entry we have it's friction;
            // when there's a second editor-level action it can move
            // back into a menu.
            SecondaryButton {
                // Stick to a thin Unicode glyph instead of the 🗑
                // emoji — emoji glyphs render at full color-glyph
                // height and made the Delete button visibly taller
                // than its peers.
                visible: !root.fragmentMode
                // Switches between 'Delete step(s)' when canvas
                // selection is non-empty and 'Delete workflow'
                // when nothing's selected. Same button click runs
                // the right action either way.
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
            // Workflow-level imports — name → path mapping that
            // `use` steps reference. Opens a dialog with the table.
            // Imports are a workflow-level concept; fragments don't
            // own their own imports map (they inherit the parent's
            // when invoked via `use`), so the button is hidden in
            // fragment view.
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
            // Fragments aren't standalone runnables — they're step
            // snippets meant to be spliced into a parent workflow.
            // Hide Run in fragment view so the user opens the parent
            // workflow to run.
            // Group selection — wraps the bounding box of the
            // currently-selected cards in an annotation rectangle.
            // Hidden until the user actually has something selected
            // so the toolbar stays quiet by default.
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

            // Undo / redo. Sit before the run controls so the
            // primary affordance (Run) stays at the right edge of
            // the toolbar. Both icons are quiet hover-revealed
            // glyphs; the labels speak for themselves at full size.
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

            // Run / debug control. When idle: Run + Debug. When in
            // a debug session: Step / Continue / Stop. When in a
            // normal run: Stop only.
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
            // Paused-mode trio. wfCtrl.paused is true while the
            // engine is awaiting a debug command between steps.
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
            // Stop is visible during any active run (debug or normal)
            // so the user can always bail.
            SecondaryButton {
                visible: !root.fragmentMode && root.running
                text: "■ Stop"
                leftPadding: 14
                rightPadding: 14
                onClicked: wfCtrl.stop_run()
            }
            // Idle "Running…" indicator for normal (non-debug) runs.
            // Debug runs surface state through Step / Continue / Stop
            // so they don't need this label.
            Text {
                visible: !root.fragmentMode && root.running && !wfCtrl.paused
                text: "⏸ Running…"
                color: Theme.text2
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                font.weight: Font.Medium
                anchors.verticalCenter: parent.verticalCenter
            }
            // Fragment-mode badge — sits in place of the workflow-only
            // action buttons (Run / Imports / Share / Delete) so the
            // user always knows they're editing a fragment, not a
            // standalone workflow. Tinted with the violet `use`
            // colour so it matches the tab-strip styling for fragment
            // tabs.
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

        // Error banner — surface the last run / save error from the
        // engine. Soft-tinted background, accent-bordered, with a
        // dismissable × so a stale error doesn't haunt the editor.
        Rectangle {
            id: errorBanner
            property bool _dismissed: false
            // Mirror last_error so the change handler reliably fires
            // (cxx-qt snake_case Q_PROPERTY → function-syntax
            // Connections handler doesn't catch it; property binding
            // does).
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
                        // bridge — the property is read-only from QML
                        // by default but we own a setter via cxx-qt.
                        // Workaround: trigger another action that
                        // resets it. For now, hide the banner client-
                        // side until next change.
                        onClicked: errorBanner._dismissed = true
                    }
                }
            }

        }

        Item {
            id: editorContent
            width: parent.width
            height: parent.height - tb.height

            // -1 means "no step selected" → inspector slides out and
            // the canvas takes the full width. selectedInnerIndex is
            // -1 when the parent itself is selected; >= 0 means the
            // user clicked an inner mini-row of a flow-control
            // container, and the inspector edits the inner step.
            //
            // selectedIndex is the "anchor" — the most recent click,
            // used by the inspector and by shift-click range
            // expansion. selectedIndices is the full set of currently
            // selected indices (object keyed by stringified index, so
            // QML's binding system sees property changes when the
            // map is replaced wholesale). The two stay in sync via
            // the _setSingleSelection / _toggleSelected /
            // _selectRange helpers below; nothing else should touch
            // either property directly.
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
                    selectedIndex = i  // most recent click is the anchor
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

            // Walk into the workflow's nested step structure and shape
            // the resulting Step the same way root.actions shapes top-
            // level steps. selectedInnerIndex < 0 → top-level lookup.
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

            // Keep selectedIndex valid as the action list changes; do
            // NOT auto-select when it's -1. Auto-selecting was popping
            // the inspector open every time a step landed from a
            // palette drop — combined with the deselect TapHandler
            // firing in the same release, you'd see the menu flash
            // in / out / in. The user opens the inspector by clicking
            // a card; reconcile only clamps when needed.
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
                // A fragment tab has fragmentPath set but no
                // workflowId — still a "loaded" state.
                visible: !root.workflowId && !root.fragmentMode
                title: "No workflow loaded"
                description: "Pick one from the library, or create a new one."
                actionLabel: ""
            }

            // ---- Three-pane layout: rail | canvas | (slide-in) inspector ----
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
                selectedIndices: editorContent.selectedIndices
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

            // Inspector container — animates width from 0 → 360 so
            // the slide-in feels driven by the panel's own arrival
            // rather than a separate translation. Canvas anchors to
            // this container's left edge, so it reflows in sync.
            Item {
                id: inspectorContainer
                // Fragments have fragmentPath but no workflowId —
                // both are valid loaded states for the editor.
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
                        // Reuse: prev/next click → navigate scope. If
                        // we're on an inner step, jump within parent's
                        // inner sequence; otherwise move along the
                        // top-level chain.
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
                    // Replace current selection with the marquee
                    // result. The anchor becomes the highest-numbered
                    // index so subsequent shift-clicks expand from
                    // there as the user expects.
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
                onDeleteInnerStepRequested: (stepIdx, innerIdx) => root._deleteInnerStep(stepIdx, innerIdx)
                onMoveStepToContainerRequested: (fromIdx, toIdx) => root._moveStepToContainer(fromIdx, toIdx)
                onOpenContainerRequested: (stepIdx) => root.pushCrumb(stepIdx)
                onOpenUseRequested: (stepIdx) => root._openUseImport(stepIdx)
                onOptionEdited: (stepIdx, path, value) => root._commitOption(stepIdx, path, value)
                onPredecessorChosen: (stepIdx, otherIdx) => root._makePredecessorOf(stepIdx, otherIdx)
                onSuccessorChosen: (stepIdx, otherIdx) => root._makeSuccessorOf(stepIdx, otherIdx)
            }

            // Floating step palette. Drag a chip onto the canvas to
            // add a step at the drop point — palette uses the canvas
            // ref to drive an in-canvas card-shaped preview ghost.
            StepPalette {
                id: paletteDockInst
                // Visible whenever a doc is loaded — both real
                // workflows (workflowId set) and fragment files
                // (fragmentPath set). Fragment edits save through
                // wfCtrl.save_fragment instead of wfCtrl.save.
                // Docked to the canvas's left edge as a vertical
                // icon strip; tooltips carry the full label so the
                // strip can stay narrow.
                visible: root.workflowId.length > 0 || root.fragmentMode
                anchors.left: canvasView.left
                anchors.verticalCenter: canvasView.verticalCenter
                anchors.leftMargin: 12
                z: 60
                canvas: canvasView
            }
        }
    }

    // Workflow-level imports manager. Maps a short name to a
    // fragment-file path; `use name` steps splice that fragment in
    // at decode time. The dialog is the only GUI surface for the
    // imports block — other than that, the .kdl `imports { name
    // "path" }` is hand-edited.
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

                        // Empty state
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

                // + Add row
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

    // Trust prompt for workflows wflow didn't author here. Shown
    // when wfCtrl emits trust_prompt_required; the engine waits for
    // confirm_trust() or cancel_trust() before doing anything.
    // Mirrors the CLI prompt's body (see src/security.rs +
    // src/cli.rs::confirm_untrusted_workflow) and the threat-model
    // pointer in REVIEW.md.
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

                // Header
                Column {
                    width: parent.width
                    spacing: 6

                    Row {
                        spacing: 10
                        // Warning glyph in accent-warm so it reads as
                        // "stop and look" without alarming red.
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

                // Step summary — scrollable in case the workflow has
                // more than ~12 enabled steps.
                ScrollView {
                    width: parent.width
                    height: parent.height
                          - parent.spacing * 2
                          - 80   // header
                          - 56   // footer
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

                // Footer
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
