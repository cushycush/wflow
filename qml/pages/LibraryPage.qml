import QtQuick
import QtQuick.Controls
import Wflow

// Library reads ~/.config/wflow/workflows/*.kdl through LibraryController
// and shapes the summaries for grid/list delegates.
Item {
    id: root
    signal newWorkflow()
    signal openWorkflow(string id)
    signal recordRequested()

    LibraryController { id: libCtrl }
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
    // Picks up workflows added by the recorder or dropped in by hand.
    onVisibleChanged: if (visible) libCtrl.refresh()
    Connections {
        target: libCtrl
        function onWorkflowsChanged() { root._refreshShaped() }
    }

    function _askDelete(id) {
        const wf = root.workflows.find(w => w.id === id)
        deleteDialog.targetId = id
        deleteDialog.targetTitle = wf ? wf.title : id
        deleteDialog.open()
    }

    WfConfirmDialog {
        id: deleteDialog
        property string targetId: ""
        property string targetTitle: ""

        title: "Delete workflow?"
        message: "This permanently deletes “" + deleteDialog.targetTitle
            + "” from your library. The KDL file is removed from disk."
        confirmText: "Delete"
        destructive: true
        onConfirmed: libCtrl.remove(deleteDialog.targetId)
    }

    property bool selectMode: false
    property var selectedIds: ({})
    readonly property int selectedCount: Object.keys(root.selectedIds).length

    function _enterSelect() {
        root.selectedIds = ({})
        root.selectMode = true
    }
    function _exitSelect() {
        root.selectedIds = ({})
        root.selectMode = false
    }
    function _toggleSelected(id) {
        const next = Object.assign({}, root.selectedIds)
        if (next[id]) delete next[id]
        else next[id] = true
        root.selectedIds = next
    }
    function _askBulkDelete() {
        if (root.selectedCount === 0) return
        bulkDeleteDialog.open()
    }

    WfConfirmDialog {
        id: bulkDeleteDialog
        title: root.selectedCount === 1
            ? "Delete 1 workflow?"
            : "Delete " + root.selectedCount + " workflows?"
        message: "This permanently deletes the selected workflows from your library. KDL files are removed from disk."
        confirmText: "Delete " + root.selectedCount
        destructive: true
        onConfirmed: {
            for (const id of Object.keys(root.selectedIds)) libCtrl.remove(id)
            root._exitSelect()
        }
    }

    // Re-pulls templates_json each open so a freshly-installed
    // package's templates show up without restarting.
    function _openNewDialog() {
        let parsed = []
        try { parsed = JSON.parse(stateCtrl.templates_json || "[]") }
        catch (e) { parsed = [] }
        newDialog.templates = parsed
        newDialog.open()
    }

    // Local-only until the bridge owns a user-ordered list; on-disk
    // order is still modified-time.
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
            title: root.selectMode
                ? (root.selectedCount + " selected")
                : "Library"
            subtitle: root.selectMode
                ? "click cards to select, Esc to cancel"
                : (root.workflows.length === 1
                    ? "1 workflow"
                    : root.workflows.length + " workflows")

            // Select-mode actions: Cancel + Delete N. Hide layout
            // switcher / + New / Record while selecting so the
            // toolbar stays focused on the bulk action.
            SecondaryButton {
                visible: root.selectMode
                text: "Cancel"
                onClicked: root._exitSelect()
            }
            PrimaryButton {
                visible: root.selectMode
                enabled: root.selectedCount > 0
                text: root.selectedCount > 0
                    ? "🗑 Delete " + root.selectedCount
                    : "🗑 Delete"
                onClicked: root._askBulkDelete()
            }

            LibraryLayoutSwitcher {
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.selectMode && root.workflows.length > 0
            }
            SecondaryButton {
                visible: !root.selectMode && root.workflows.length > 0
                text: "Select"
                onClicked: root._enterSelect()
            }
            PrimaryButton {
                visible: !root.selectMode
                text: "+ New workflow"
                onClicked: root._openNewDialog()
            }
            SecondaryButton {
                visible: !root.selectMode
                text: "● Record"
                onClicked: root.recordRequested()
            }
        }

        Shortcut {
            sequence: "Escape"
            enabled: root.visible && root.selectMode
            onActivated: root._exitSelect()
        }

        Item {
            width: parent.width
            height: parent.height - tb.height

            // First-run uses a full welcome card; returning-empty uses
            // the concise variant. kind drives the hero glyph.
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
                            selectMode: root.selectMode
                            selectedIds: root.selectedIds
                            onOpenWorkflow: (id) => root.openWorkflow(id)
                            onDeleteRequested: (id) => root._askDelete(id)
                            onDuplicateRequested: (id) => libCtrl.duplicate(id)
                            onToggleSelected: (id) => root._toggleSelected(id)
                        }
                    }
                    Component {
                        id: listComp
                        LibraryList {
                            width: variantLoader.width
                            workflows: root.workflows
                            selectMode: root.selectMode
                            selectedIds: root.selectedIds
                            onOpenWorkflow: (id) => root.openWorkflow(id)
                            onReorderRequested: (from, to) => root.moveWorkflow(from, to)
                            onDeleteRequested: (id) => root._askDelete(id)
                            onDuplicateRequested: (id) => libCtrl.duplicate(id)
                            onToggleSelected: (id) => root._toggleSelected(id)
                        }
                    }
                }
            }
        }
    }
}
