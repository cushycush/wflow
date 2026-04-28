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
    readonly property int activeStepIndex: wfCtrl.active_step
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
        editorContent.selectedIndex = -1
        editorContent.selectedInnerIndex = -1
    }

    function popCrumbTo(depth) {
        if (depth < 0) depth = 0
        if (depth >= root.crumb.length) return
        root.crumb = root.crumb.slice(0, depth)
        editorContent.selectedIndex = -1
        editorContent.selectedInnerIndex = -1
    }

    readonly property var actions: {
        // Shape the Rust-side Step[] into the { kind, summary, value, rawPrimary, editable }
        // that the split-inspector delegates expect. Driven by the
        // crumb: at top level this is wf.steps; inside a container,
        // it's the inner step list at that depth.
        const out = []
        const steps = root._currentSteps
        for (const s of steps) {
            out.push(root._stepToAction(s))
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
        editorContent.selectedIndex = steps.length - 1
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
        const wf = JSON.parse(JSON.stringify(root.workflow))
        const steps = _stepsAtCrumb(wf)
        if (!steps) return
        if (stepIndex < 0 || stepIndex >= steps.length) return
        steps.splice(stepIndex, 1)
        root.workflow = wf
        // Keep selection valid: clamp into range, or collapse the
        // inspector when no steps remain.
        if (steps.length === 0) {
            editorContent.selectedIndex = -1
        } else if (editorContent.selectedIndex >= steps.length) {
            editorContent.selectedIndex = steps.length - 1
        }
        _scheduleSave()
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
            editorContent.selectedIndex = to
        } else if (from < sel && to >= sel) {
            editorContent.selectedIndex = sel - 1
        } else if (from > sel && to <= sel) {
            editorContent.selectedIndex = sel + 1
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
        const steps = root._currentSteps
        if (stepIndex < 0 || stepIndex >= steps.length) return
        const step = steps[stepIndex]
        if (!step || !step.action || step.action.kind !== "use") return
        const name = step.action.name || ""
        if (name.length === 0) return
        const abs = wfCtrl.resolve_import_path(name) || ""
        if (abs.length === 0) {
            // Either the name isn't in imports or the path didn't
            // resolve. Open a placeholder fragment tab named after
            // the import — at least the user sees what they tried
            // to open. Future: surface a proper error toast.
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
        editorContent.selectedIndex = newContainerIdx
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
        // Fragment view is read-only — every mutation handler still
        // runs (the user might inspect-but-not-touch), and root.workflow
        // updates so the UI reflects edits live, but we never schedule
        // a save back to disk. The save is silently dropped at the
        // boundary so the rest of the page (mutation helpers, action
        // bindings) doesn't need fragment-mode branching.
        if (root.fragmentMode) return
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
        const newId = wfCtrl.save(json)
        if (newId && newId.length > 0) {
            root.saveState = "saved"
            savedToast.restart()
        } else {
            root.saveState = "error"
        }
    }

    Timer { id: saveTimer; interval: 600; repeat: false; onTriggered: root._saveNow() }
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
        if (!root.workflowId || root.workflowId.length === 0) return
        const steps = (root.workflow && root.workflow.steps) || []
        if (steps.length === 0) return
        _stableIdsEnsured = true
        wfCtrl.save(JSON.stringify(root.workflow))
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
    on_WorkflowJsonMirrorChanged: {
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
        function onRunningChanged() {
            // Clear previous statuses at the start of a fresh run so stale
            // glyphs from the last run don't bleed into the new one.
            if (wfCtrl.running) root.stepStatuses = ({})
        }
        function onStep_done(index, status, message) {
            const next = Object.assign({}, root.stepStatuses)
            next[index] = status
            root.stepStatuses = next
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

            // Compact save-state indicator to the left of the action buttons.
            Text {
                visible: root.saveState !== "idle"
                anchors.verticalCenter: parent.verticalCenter
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontXs
                font.weight: Font.Medium
                text: {
                    switch (root.saveState) {
                    case "dirty":  return "● unsaved"
                    case "saving": return "● saving…"
                    case "saved":  return "✓ saved"
                    case "error":  return "✗ save failed"
                    }
                    return ""
                }
                color: {
                    switch (root.saveState) {
                    case "dirty":  return Theme.text3
                    case "saving": return Theme.accent
                    case "saved":  return Theme.ok
                    case "error":  return Theme.err
                    }
                    return Theme.text3
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
                text: "× Delete"
                onClicked: root._askDelete()
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
            PrimaryButton {
                id: runBtn
                visible: !root.fragmentMode
                text: root.running ? "⏸ Running…" : "▶ Run"
                leftPadding: 18
                rightPadding: 18
                enabled: (root.actions || []).length > 0 && !root.running
                onClicked: wfCtrl.run()
            }
            // Fragment-mode badge — sits in place of the action
            // buttons so the user always knows they're looking at a
            // read-only view.
            Rectangle {
                visible: root.fragmentMode
                anchors.verticalCenter: parent.verticalCenter
                width: badgeText.implicitWidth + 16
                height: 24
                radius: 12
                color: Theme.surface3
                border.color: Theme.lineSoft
                border.width: 1
                Text {
                    id: badgeText
                    anchors.centerIn: parent
                    text: "fragment · read-only"
                    color: Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    font.weight: Font.Medium
                }
            }
        }

        // Error banner — surface the last run / save error from the engine.
        Rectangle {
            width: parent.width
            height: visible ? 36 : 0
            visible: wfCtrl.last_error.length > 0
            color: Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.15)
            border.color: Theme.err
            border.width: 1

            Row {
                anchors.fill: parent
                anchors.leftMargin: 24
                anchors.rightMargin: 24
                spacing: 10
                Text {
                    text: "● " + wfCtrl.last_error
                    color: Theme.err
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    width: parent.width - 80
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
            property int selectedIndex: -1
            property int selectedInnerIndex: -1
            readonly property bool inspectorOpen: selectedIndex >= 0

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
                visible: !root.workflowId
                title: "No workflow loaded"
                description: "Pick one from the library, or create a new one."
                actionLabel: ""
            }

            // ---- Three-pane layout: rail | canvas | (slide-in) inspector ----
            StepListRail {
                id: rail
                visible: root.workflowId.length > 0
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
                stepStatuses: root.stepStatuses

                showTutorial: _shouldShowBlankTutorial
                onTutorialDismissed: {
                    stateCtrl.mark_tutorial_seen("blank_workflow")
                    root._tutorialDismissedThisSession = true
                }

                onSelectRequested: (i) => { editorContent.selectedIndex = i }
                onAddStepRequested: (kind) => {
                    root._addStep(kind)
                    editorContent.selectedIndex = (root.actions || []).length - 1
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
                visible: root.workflowId.length > 0
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
                        editorContent.selectedIndex = -1
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
                            editorContent.selectedIndex = i
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
                visible: root.workflowId.length > 0
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
                stepStatuses: root.stepStatuses
                onSelectStep: (i) => {
                    editorContent.selectedIndex = i
                    editorContent.selectedInnerIndex = -1
                }
                onDeselectRequested: {
                    editorContent.selectedIndex = -1
                    editorContent.selectedInnerIndex = -1
                }
                onSelectInnerStep: (parentIdx, innerIdx) => {
                    editorContent.selectedIndex = parentIdx
                    editorContent.selectedInnerIndex = innerIdx
                }
                onAddStepAtRequested: (kind, x, y) => root._addStepAt(kind, x, y)
                onDeleteStepRequested: (i) => root._deleteStep(i)
                onAddInnerStepRequested: (stepIdx, kind) => root._addInnerStep(stepIdx, kind)
                onDeleteInnerStepRequested: (stepIdx, innerIdx) => root._deleteInnerStep(stepIdx, innerIdx)
                onMoveStepToContainerRequested: (fromIdx, toIdx) => root._moveStepToContainer(fromIdx, toIdx)
                onOpenContainerRequested: (stepIdx) => root.pushCrumb(stepIdx)
                onOpenUseRequested: (stepIdx) => root._openUseImport(stepIdx)
                onPredecessorChosen: (stepIdx, otherIdx) => root._makePredecessorOf(stepIdx, otherIdx)
                onSuccessorChosen: (stepIdx, otherIdx) => root._makeSuccessorOf(stepIdx, otherIdx)
            }

            // Floating step palette. Drag a chip onto the canvas to
            // add a step at the drop point — palette uses the canvas
            // ref to drive an in-canvas card-shaped preview ghost.
            StepPalette {
                // Hidden in fragment view — fragments are read-only,
                // so dragging in a new step would have nowhere to
                // save to.
                visible: !root.fragmentMode && root.workflowId.length > 0
                anchors.bottom: canvasView.bottom
                anchors.horizontalCenter: canvasView.horizontalCenter
                anchors.bottomMargin: 18
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
