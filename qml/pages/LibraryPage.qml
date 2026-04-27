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
                id:        wf.id,
                title:     wf.title,
                subtitle:  wf.subtitle && wf.subtitle.length > 0 ? wf.subtitle : "",
                steps:     wf.steps || 0,
                lastRun:   root._humanizeTs(wf.last_run),
                runs:      0,                 // real counter lands with run-history persistence
                kinds:     wf.kinds || [],
                folder:    wf.folder || "",
                _modified: wf.modified || "",  // ISO string, used for sort comparisons
                _lastRun:  wf.last_run || ""
            })
        }
        return out
    }

    property var workflows: []
    // ---- Library filters ----
    property string searchQuery: ""
    // "" means All; "__top__" means workflows with no folder; any
    // other value is a folder name.
    property string currentFolder: ""
    // "recent" (default — modified desc), "name" (asc), "last_run".
    property string sortBy: "recent"
    property var folderList: []

    // Apply search + folder filter and sort.
    readonly property var filtered: {
        const q = (root.searchQuery || "").trim().toLowerCase()
        const fld = root.currentFolder
        let out = (root.workflows || []).filter(w => {
            if (fld === "__top__" && w.folder !== "") return false
            if (fld !== "" && fld !== "__top__" && w.folder !== fld) return false
            if (q.length === 0) return true
            return (w.title || "").toLowerCase().indexOf(q) >= 0
                || (w.subtitle || "").toLowerCase().indexOf(q) >= 0
                || (w.kinds || []).some(k => (k || "").toLowerCase().indexOf(q) >= 0)
        })
        if (root.sortBy === "name") {
            out = out.slice().sort((a, b) => (a.title || "").localeCompare(b.title || ""))
        } else if (root.sortBy === "last_run") {
            // Most-recent first; never-run goes last.
            out = out.slice().sort((a, b) => {
                if (!a._lastRun && !b._lastRun) return 0
                if (!a._lastRun) return 1
                if (!b._lastRun) return -1
                return b._lastRun.localeCompare(a._lastRun)
            })
        } else {
            // recent — modified desc, fall through to created if missing.
            out = out.slice().sort((a, b) => (b._modified || "").localeCompare(a._modified || ""))
        }
        return out
    }

    function _refreshShaped() {
        try {
            const raw = JSON.parse(libCtrl.workflows || "[]")
            root.workflows = root._shape(raw)
        } catch (e) {
            root.workflows = []
        }
        try {
            root.folderList = JSON.parse(libCtrl.folders() || "[]")
        } catch (e) {
            root.folderList = []
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

    // ---- Bulk selection / delete ----
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
            title: root.selectMode
                ? (root.selectedCount + " selected")
                : "Library"
            subtitle: root.selectMode
                ? "click cards to select, Esc to cancel"
                : (root.workflows.length === 1
                    ? "1 workflow"
                    : root.workflows.length + " workflows")

            // Select-mode actions: Cancel + Move to folder + Delete N.
            // Hide layout switcher / + New / Record while selecting
            // so the toolbar stays focused on the bulk action.
            SecondaryButton {
                visible: root.selectMode
                text: "Cancel"
                onClicked: root._exitSelect()
            }
            SecondaryButton {
                visible: root.selectMode
                enabled: root.selectedCount > 0
                text: "↳ Move to…"
                onClicked: moveToFolderMenu.popup()
            }
            PrimaryButton {
                visible: root.selectMode
                enabled: root.selectedCount > 0
                text: root.selectedCount > 0
                    ? "× Delete " + root.selectedCount
                    : "× Delete"
                onClicked: root._askBulkDelete()
            }

            WfMenu {
                id: moveToFolderMenu
                WfMenuItem {
                    text: "(Top level — clear folder)"
                    onTriggered: {
                        for (const id of Object.keys(root.selectedIds)) {
                            libCtrl.set_folder(id, "")
                        }
                        root._exitSelect()
                    }
                }
                MenuSeparator {}
                Repeater {
                    model: root.folderList
                    delegate: WfMenuItem {
                        text: modelData
                        onTriggered: {
                            for (const id of Object.keys(root.selectedIds)) {
                                libCtrl.set_folder(id, modelData)
                            }
                            root._exitSelect()
                        }
                    }
                }
                MenuSeparator {}
                WfMenuItem {
                    text: "+ New folder…"
                    onTriggered: newFolderDialog.open()
                }
            }

            // Default-mode actions.
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

        // Esc cancels select mode (matches the subtitle hint).
        Shortcut {
            sequence: "Escape"
            enabled: root.visible && root.selectMode
            onActivated: root._exitSelect()
        }

        // Search + sort row sits between the TopBar and the body.
        // Light surface so it reads as a sub-toolbar.
        Rectangle {
            width: parent.width
            height: 48
            color: Theme.surface
            visible: root.workflows.length > 0 && !root.selectMode

            Row {
                anchors.fill: parent
                anchors.leftMargin: 24
                anchors.rightMargin: 24
                spacing: 12

                // Search bar
                Rectangle {
                    width: 320
                    height: 32
                    radius: 6
                    anchors.verticalCenter: parent.verticalCenter
                    color: searchInput.activeFocus ? Theme.bg : Theme.surface2
                    border.color: searchInput.activeFocus ? Theme.accent : Theme.lineSoft
                    border.width: 1
                    Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 8
                        spacing: 6
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "⌕"
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: 14
                        }
                        TextField {
                            id: searchInput
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 6 - 14 - 8
                            placeholderText: "Search workflows…"
                            color: Theme.text
                            placeholderTextColor: Theme.text3
                            selectionColor: Theme.accentWash(0.4)
                            selectedTextColor: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            background: Item {}
                            onTextChanged: root.searchQuery = text
                        }
                    }
                }

                Item { width: parent.width - 320 - 200 - 12 * 2; height: 1 }

                // Sort dropdown — visual-only Rectangle wrapping a
                // hidden ComboBox so the picker matches the rest of
                // the chrome. Recent is the default.
                Rectangle {
                    width: 200
                    height: 32
                    radius: 6
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.surface2
                    border.color: Theme.lineSoft
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 8
                        spacing: 4

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Sort:"
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontXs
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.sortBy === "name"     ? "A → Z"
                                : root.sortBy === "last_run" ? "Last run"
                                                              : "Recently modified"
                            color: Theme.text2
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            font.weight: Font.Medium
                            width: parent.width - 38 - 14
                            elide: Text.ElideRight
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "▾"
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: 10
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: sortMenu.popup()
                    }

                    WfMenu {
                        id: sortMenu
                        WfMenuItem {
                            text: "Recently modified"
                            onTriggered: root.sortBy = "recent"
                        }
                        WfMenuItem {
                            text: "Last run"
                            onTriggered: root.sortBy = "last_run"
                        }
                        WfMenuItem {
                            text: "Name (A → Z)"
                            onTriggered: root.sortBy = "name"
                        }
                    }
                }
            }
        }

        // Hairline under sub-toolbar.
        Rectangle {
            width: parent.width
            height: 1
            color: Theme.lineSoft
            visible: root.workflows.length > 0 && !root.selectMode
        }

        Item {
            width: parent.width
            height: parent.height - tb.height
                  - (root.workflows.length > 0 && !root.selectMode ? 49 : 0)

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

            // Folder sidebar — All / Top-level / each named folder.
            // Click a row to filter the grid; '+ New folder' inline-
            // creates an entry by typing into the input. Folders
            // come from workflows.toml meta — not a separate file —
            // so creating one is a side-effect of moving a workflow
            // into it.
            Rectangle {
                id: folderRail
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 200
                color: Theme.surface
                border.color: Theme.lineSoft
                border.width: 1
                visible: root.workflows.length > 0

                Column {
                    anchors.fill: parent
                    anchors.topMargin: 16
                    anchors.bottomMargin: 12
                    spacing: 0

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 16
                        text: "FOLDERS"
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: 10
                        font.weight: Font.Bold
                        font.letterSpacing: 1.2
                        bottomPadding: 10
                    }

                    Repeater {
                        model: [
                            { id: "",        label: "All workflows", glyph: "▦" },
                            { id: "__top__", label: "Top level",     glyph: "·" }
                        ]
                        delegate: folderRowComp
                    }

                    // Hairline separator with breathing room above
                    // and below — Rectangle has no padding props, so
                    // wrap in an Item that owns the spacing.
                    Item {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 17
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            height: 1
                            color: Theme.lineSoft
                        }
                    }

                    Repeater {
                        model: root.folderList.map(name => ({
                            id: name, label: name, glyph: "▢"
                        }))
                        delegate: folderRowComp
                    }

                    // + New folder inline-input. Typing a name +
                    // Enter calls libCtrl.set_folder on… nothing,
                    // since folders are derived from workflows. So
                    // instead we stash the name and prompt to drop
                    // a workflow in via right-click.
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        height: 32
                        radius: 6
                        color: addFolderArea.containsMouse ? Theme.surface2 : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.durFast } }

                        Row {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 8
                            spacing: 6
                            Text {
                                text: "+"
                                color: Theme.accent
                                font.family: Theme.familyBody
                                font.pixelSize: 14
                                font.weight: Font.Bold
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: "New folder…"
                                color: Theme.text2
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontSm
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        MouseArea {
                            id: addFolderArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: newFolderDialog.open()
                        }
                    }
                }
            }

            ScrollView {
                anchors.left: folderRail.visible ? folderRail.right : parent.left
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.bottom: parent.bottom
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
                            workflows: root.filtered
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
                            workflows: root.filtered
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

    // Reusable folder-row component for the sidebar. Delegate
    // shape: { id, label, glyph } — id is "", "__top__", or any
    // user folder name. Count is derived from root.workflows so it
    // updates whenever the library refreshes.
    Component {
        id: folderRowComp
        Rectangle {
            readonly property string folderId: modelData.id
            readonly property string rowLabel: modelData.label
            readonly property string rowGlyph: modelData.glyph
            readonly property int rowCount: {
                const list = root.workflows || []
                if (folderId === "")        return list.length
                if (folderId === "__top__") return list.filter(w => !w.folder).length
                return list.filter(w => w.folder === folderId).length
            }
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            // Hide the Top-level row unless there's something there
            // or it's the active filter (so the user can see why the
            // grid is empty).
            visible: folderId !== "__top__"
                || rowCount > 0
                || root.currentFolder === "__top__"
            height: visible ? 32 : 0
            radius: 6
            readonly property bool isCurrent: root.currentFolder === folderId
            color: dropTarget.containsDrag
                ? Theme.accentWash(0.28)
                : (isCurrent
                    ? Theme.accentWash(0.16)
                    : (folderRowArea.containsMouse ? Theme.surface2 : "transparent"))
            border.color: dropTarget.containsDrag ? Theme.accent : "transparent"
            border.width: dropTarget.containsDrag ? 1 : 0
            Behavior on color { ColorAnimation { duration: Theme.durFast } }
            Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

            Row {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 8
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: rowGlyph
                    color: isCurrent ? Theme.accent : Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: 13
                    width: 16
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: rowLabel
                    color: isCurrent ? Theme.accent : Theme.text
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    font.weight: isCurrent ? Font.DemiBold : Font.Medium
                    elide: Text.ElideRight
                    width: parent.width - 16 - 8 - countLabel.width - 8
                }
                Text {
                    id: countLabel
                    anchors.verticalCenter: parent.verticalCenter
                    text: rowCount
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: Theme.fontXs
                }
            }
            MouseArea {
                id: folderRowArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.currentFolder = folderId
            }

            // Drop target — accepts library card drags. Empty
            // string folder = top-level (clears the workflow's
            // folder field); "All workflows" doesn't accept drops
            // (it's a view filter, not a real bucket).
            //
            // Read the workflow id off drop.source (the dragged
            // Rectangle delegate) directly. Drag.mimeData via
            // Drag.Internal didn't reliably surface in
            // getDataAsString — drop.source carries the live item
            // with its `wf` property attached.
            DropArea {
                id: dropTarget
                anchors.fill: parent
                keys: folderId === "" ? [] : ["wflow/workflow-id"]
                onDropped: (drop) => {
                    const src = drop.source
                    const id = (src && src.wf) ? src.wf.id : ""
                    if (!id) return
                    const target = (folderId === "__top__") ? "" : folderId
                    libCtrl.set_folder(id, target)
                    drop.accept()
                }
            }
        }
    }

    // New-folder picker dialog. Asks the user to drop a workflow
    // into a freshly-named folder via a select-then-name flow —
    // folders only exist as long as a workflow references them.
    Dialog {
        id: newFolderDialog
        parent: Overlay.overlay
        modal: true
        title: ""

        width: 460
        height: 220
        anchors.centerIn: parent

        background: Rectangle {
            color: Theme.surface
            radius: Theme.radiusMd
            border.color: Theme.line
            border.width: 1
        }

        function _commit() {
            const name = newFolderInput.text.trim()
            if (name.length === 0) return
            // Persist as a real subdirectory under the workflows
            // root so the folder survives a restart even with no
            // workflows in it. The bridge refresh then re-emits
            // workflowsChanged, which calls _refreshShaped() and
            // pulls the new folder name into folderList.
            libCtrl.create_folder(name)
            root.currentFolder = name
            newFolderInput.text = ""
            newFolderDialog.close()
        }

        // Reset whenever the dialog opens so leftover text doesn't
        // greet the user on a re-open, and focus the input.
        onOpened: {
            newFolderInput.text = ""
            newFolderInput.forceActiveFocus()
        }

        contentItem: Item {
            anchors.fill: parent
            Column {
                anchors.fill: parent
                anchors.margins: 24
                spacing: 14

                Text {
                    text: "Create a folder"
                    color: Theme.text
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontLg
                    font.weight: Font.DemiBold
                }
                Text {
                    text: "Folders live as a tag on each workflow — pick a name now and drop any workflow on the folder to move it in."
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    wrapMode: Text.WordWrap
                    width: parent.width
                }
                Rectangle {
                    width: parent.width
                    height: 36
                    radius: 6
                    color: Theme.bg
                    border.color: newFolderInput.activeFocus ? Theme.accent : Theme.lineSoft
                    border.width: 1
                    TextField {
                        id: newFolderInput
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        placeholderText: "Folder name"
                        color: Theme.text
                        placeholderTextColor: Theme.text3
                        selectionColor: Theme.accentWash(0.4)
                        selectedTextColor: Theme.text
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        background: Item {}
                        // Enter / Return submits — TextField fires
                        // onAccepted when the input is in an
                        // single-line + valid state.
                        onAccepted: newFolderDialog._commit()
                    }
                }

                Row {
                    width: parent.width
                    spacing: 8
                    layoutDirection: Qt.RightToLeft

                    PrimaryButton {
                        text: "Create"
                        enabled: newFolderInput.text.trim().length > 0
                        onClicked: newFolderDialog._commit()
                    }
                    SecondaryButton {
                        text: "Cancel"
                        onClicked: {
                            newFolderInput.text = ""
                            newFolderDialog.close()
                        }
                    }
                }
            }
        }
    }
}
