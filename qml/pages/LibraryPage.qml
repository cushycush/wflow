import QtQuick
import QtQuick.Controls
import Wflow

// Local library of user-authored workflows.
//
// Data flows through LibraryController (a cxx-qt QObject registered by the
// Rust side). It reads $XDG_CONFIG_HOME/wflow/workflows/*.kdl on construction
// and exposes the list as a JSON string we parse here. QML components want
// camelCased keys + a few display-only fields, so we shape the summaries
// into a `workflows` array that the grid/list delegates already understand.
Item {
    id: root
    signal newWorkflow()
    signal openWorkflow(string id)
    signal recordRequested()

    LibraryController { id: libCtrl }
    // Drives the first-launch welcome card + the New-workflow dialog's
    // template list. Per-page instance is fine for v0.3 — the only
    // mutating call here is mark_first_run_seen, persisted to disk
    // immediately, and no other page reads is_first_run reactively.
    StateController { id: stateCtrl }

    function _humanizeTs(iso) {
        if (!iso) return "never"
        const then = new Date(iso)
        const diffMs = Date.now() - then.getTime()
        if (isNaN(diffMs) || diffMs < 0) return then.toLocaleDateString()
        const mins = Math.floor(diffMs / 60000)
        if (mins < 1)  return "just now"
        if (mins < 60) return mins + "m ago"
        const hrs  = Math.floor(mins / 60)
        if (hrs  < 24) return hrs + "h ago"
        const days = Math.floor(hrs / 24)
        if (days === 1) return "yesterday"
        if (days < 14)  return days + "d ago"
        return then.toLocaleDateString()
    }

    function _shape(rawList) {
        const out = []
        for (const wf of rawList) {
            out.push({
                id:       wf.id,
                title:    wf.title,
                subtitle: wf.subtitle && wf.subtitle.length > 0 ? wf.subtitle : "",
                steps:    wf.steps || 0,
                lastRun:  root._humanizeTs(wf.last_run),
                runs:     0,                 // real counter lands with run-history persistence
                kinds:    wf.kinds || []
            })
        }
        return out
    }

    property var workflows: []

    function _refreshShaped() {
        try {
            const raw = JSON.parse(libCtrl.workflows || "[]")
            root.workflows = root._shape(raw)
        } catch (e) {
            root.workflows = []
        }
    }

    Component.onCompleted: _refreshShaped()
    // Refresh whenever the library page comes back into view, so a
    // workflow saved by the recorder (or hand-dropped into the
    // library dir) shows up without restarting the app. Cheap —
    // libCtrl.refresh() reads ~/.config/wflow/workflows once.
    onVisibleChanged: if (visible) libCtrl.refresh()
    Connections {
        target: libCtrl
        function onWorkflowsChanged() { root._refreshShaped() }
    }

    // Open the New-workflow dialog and feed it the latest template
    // list. Pulling templates_json on each open keeps a freshly-
    // installed package's templates discoverable without restarting.
    function _openNewDialog() {
        let parsed = []
        try { parsed = JSON.parse(stateCtrl.templates_json || "[]") }
        catch (e) { parsed = [] }
        newDialog.templates = parsed
        newDialog.open()
    }

    // Drag-to-reorder is local-only until the bridge owns a user-ordered
    // list. For now splicing the shaped array gives the ListView its
    // move/displaced transitions; the on-disk order is by modified-time.
    function moveWorkflow(from, to) {
        if (from === to) return
        const a = root.workflows.slice()
        const [item] = a.splice(from, 1)
        a.splice(to, 0, item)
        root.workflows = a
    }

    Column {
        anchors.fill: parent
        spacing: 0

        TopBar {
            id: tb
            width: parent.width
            title: "Library"
            subtitle: root.workflows.length === 1
                ? "1 workflow"
                : root.workflows.length + " workflows"

            LibraryLayoutSwitcher {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.workflows.length > 0
            }

            PrimaryButton {
                text: "+ New workflow"
                onClicked: root._openNewDialog()
            }
            SecondaryButton {
                text: "● Record"
                onClicked: root.recordRequested()
            }
        }

        Item {
            width: parent.width
            height: parent.height - tb.height

            // Empty state — two variants.
            //
            //   - First run (state.toml absent): full welcome card with
            //     hero glyph, GUI + KDL framing, primary "New" + secondary
            //     "Record" CTAs.
            //   - Returning user (library was non-empty, now empty): the
            //     concise existing copy.
            //
            // The kind property switches the hero glyph; the actual copy
            // is per-variant since the welcome wants to set expectations
            // and the empty state just wants to point at the next action.
            EmptyState {
                anchors.fill: parent
                visible: root.workflows.length === 0

                kind: stateCtrl.is_first_run ? "first-run" : "empty"

                title: stateCtrl.is_first_run
                    ? "Welcome to wflow"
                    : "No workflows yet"

                description: stateCtrl.is_first_run
                    ? "wflow runs sequences of keystrokes, clicks, shell commands, and waits — Shortcuts for Linux, with a plain-text workflow file underneath. Pick a starting point or record one from real input."
                    : "Create a new workflow by hand, or hit Record and wflow will transcribe a sequence of keys, clicks, and commands into one."

                actionLabel: stateCtrl.is_first_run ? "+ New workflow" : "● Record a workflow"
                secondaryActionLabel: stateCtrl.is_first_run ? "● Record a workflow" : ""

                onActionClicked: {
                    if (stateCtrl.is_first_run) {
                        stateCtrl.mark_first_run_seen()
                        root._openNewDialog()
                    } else {
                        root.recordRequested()
                    }
                }
                onSecondaryActionClicked: {
                    stateCtrl.mark_first_run_seen()
                    root.recordRequested()
                }
            }

            // The New-workflow dialog. Templates list is populated when
            // the dialog opens so it picks up filesystem changes if the
            // user installed a templates package mid-session.
            NewWorkflowDialog {
                id: newDialog
                parent: Overlay.overlay
                onCreateBlankRequested: {
                    const id = libCtrl.new_workflow("Untitled")
                    if (id && id.length > 0) root.openWorkflow(id)
                    else root.newWorkflow()
                }
                onCreateFromTemplateRequested: (templateId) => {
                    const id = stateCtrl.create_from_template(templateId)
                    if (id && id.length > 0) root.openWorkflow(id)
                }
                onRecordRequested: root.recordRequested()
            }

            ScrollView {
                anchors.fill: parent
                visible: root.workflows.length > 0
                contentWidth: availableWidth
                clip: true

                Item {
                    width: parent.width
                    height: variantLoader.item ? variantLoader.item.height + 48 : 200

                    Loader {
                        id: variantLoader
                        x: 24; y: 24
                        width: parent.width - 48

                        sourceComponent: LibraryLayout.variant === 0 ? gridComp : listComp

                        opacity: 0
                        Component.onCompleted: opacity = 1
                        onSourceComponentChanged: {
                            opacity = 0
                            fadeIn.restart()
                        }
                        Timer {
                            id: fadeIn
                            interval: 30
                            onTriggered: variantLoader.opacity = 1
                        }
                        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                    }

                    Component {
                        id: gridComp
                        LibraryGrid {
                            width: variantLoader.width
                            workflows: root.workflows
                            onOpenWorkflow: (id) => root.openWorkflow(id)
                            onDeleteRequested: (id) => libCtrl.remove(id)
                            onDuplicateRequested: (id) => libCtrl.duplicate(id)
                        }
                    }
                    Component {
                        id: listComp
                        LibraryList {
                            width: variantLoader.width
                            workflows: root.workflows
                            onOpenWorkflow: (id) => root.openWorkflow(id)
                            onReorderRequested: (from, to) => root.moveWorkflow(from, to)
                            onDeleteRequested: (id) => libCtrl.remove(id)
                            onDuplicateRequested: (id) => libCtrl.duplicate(id)
                        }
                    }
                }
            }
        }
    }
}
