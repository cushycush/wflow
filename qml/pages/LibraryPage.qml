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

    // Exposed for the first-run TutorialCoach.
    property alias topBar: tb
    property alias folderRail: folderRail

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
    // "" means All workflows (across every folder); "__top__" means
    // workflows with no folder assignment; any other value is a
    // folder name (potentially nested as "a/b"). Default is Top
    // level so a folder-organised library doesn't dump every nested
    // workflow into one giant page on launch.
    property string currentFolder: "__top__"
    // "recent" (default — modified desc), "name" (asc), "last_run".
    property string sortBy: "recent"
    property var folderList: []

    // Per-folder expand/collapse state for the sidebar tree. Map
    // keyed by full path; value is true when expanded. Auto-expand
    // ancestors of the active folder so navigating into "a/b" keeps
    // the path visible. Persisting this across sessions is a future
    // enhancement; for now it resets on app launch.
    property var expandedFolders: ({})

    function _setExpanded(path, on) {
        const next = Object.assign({}, root.expandedFolders)
        if (on) next[path] = true
        else delete next[path]
        root.expandedFolders = next
    }

    function _expandAncestors(path) {
        if (!path || path.length === 0) return
        const parts = path.split("/")
        const next = Object.assign({}, root.expandedFolders)
        // Expand every prefix INCLUDING the path itself, so opening a
        // folder reveals its direct children in the sidebar tree.
        for (let i = 1; i <= parts.length; ++i) {
            next[parts.slice(0, i).join("/")] = true
        }
        root.expandedFolders = next
    }

    onCurrentFolderChanged: {
        if (currentFolder && currentFolder !== "" && currentFolder !== "__top__") {
            _expandAncestors(currentFolder)
        }
    }

    // Build a tree of folder nodes from the flat folderList paths,
    // then flatten back to a render order honouring expanded state.
    // Each entry in `visibleTree` is { name, fullPath, depth,
    // hasChildren, expanded } so the sidebar Repeater can lay out
    // indented rows with chevrons.
    readonly property var visibleTree: {
        const paths = (root.folderList || []).slice().sort()
        // Build child-of map: parent → ordered children paths.
        const childrenOf = {}
        const allNodes = {}
        for (const p of paths) {
            const lastSlash = p.lastIndexOf("/")
            const parent = lastSlash < 0 ? "" : p.slice(0, lastSlash)
            const name = lastSlash < 0 ? p : p.slice(lastSlash + 1)
            if (!childrenOf[parent]) childrenOf[parent] = []
            childrenOf[parent].push(p)
            allNodes[p] = { name: name, fullPath: p }
        }
        const out = []
        function walk(parent, depth) {
            const kids = childrenOf[parent] || []
            for (const path of kids) {
                const node = allNodes[path]
                const grandkids = childrenOf[path] || []
                out.push({
                    name: node.name,
                    fullPath: path,
                    depth: depth,
                    hasChildren: grandkids.length > 0,
                    expanded: !!root.expandedFolders[path]
                })
                if (root.expandedFolders[path]) {
                    walk(path, depth + 1)
                }
            }
        }
        walk("", 0)
        return out
    }

    // Folders that should appear as cards in the grid for the current
    // view. At "__top__" / "" → direct top-level children. Inside
    // folder "a" → direct children "a/X" (rendered as "X"). Filtered
    // by search query so typing "dev" highlights `dev`-named folders
    // alongside matching workflows.
    readonly property var visibleFolders: {
        const q = (root.searchQuery || "").trim().toLowerCase()
        const fld = root.currentFolder
        // Determine the parent prefix for "direct child" matching.
        // Empty / __top__ → parent is "" (no prefix); a real folder
        // → parent is "<folder>/".
        const isTopLevel = fld === "" || fld === "__top__"
        const prefix = isTopLevel ? "" : (fld + "/")
        const out = []
        const seen = {}
        for (const full of root.folderList || []) {
            // Direct child: full path starts with `prefix` and the
            // remainder has no slashes.
            if (!full.startsWith(prefix)) continue
            const tail = full.slice(prefix.length)
            if (tail.length === 0 || tail.indexOf("/") >= 0) continue
            if (seen[full]) continue
            seen[full] = true
            if (q.length > 0 && tail.toLowerCase().indexOf(q) < 0) continue
            out.push({ name: tail, fullPath: full })
        }
        out.sort((a, b) => a.name.localeCompare(b.name))
        return out
    }

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

    // Library-level publish flow. Same dialog + ExploreController
    // pair the editor uses; instantiated once here so any card on
    // any layout (grid / list / future tile) can fire the flow
    // without each delegate carrying its own bridge.
    function _openPublish(id) {
        const wf = root.workflows.find(w => w.id === id)
        publishDialog.workflowId = id
        publishDialog.workflowTitle = wf ? wf.title : id
        publishDialog.open()
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
            publishDialog.lastError = "signed out — sign in again to publish"
        }
    }

    PublishDialog {
        id: publishDialog
        busy: publishCatalog.loading
        onPublishRequested: (workflowId, description, readme, tagsJson, visibility) => {
            publishCatalog.publish_workflow(
                workflowId, description, readme, tagsJson, visibility
            )
        }
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
                    text: "Top level (clears folder)"
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
            // (Record button removed — the Record tab in the floating
            // nav pill is the canonical entry point now.)
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
                    ? "wflow runs sequences of keystrokes, clicks, shell commands, and waits. Shortcuts for Linux, with a plain-text workflow file underneath. Pick a starting point or record one from real input."
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

            // Right-click on empty canvas — quick way to create a
            // new workflow or folder without trekking up to the
            // topbar action row.
            WfMenu {
                id: canvasContextMenu
                WfMenuItem {
                    text: "+ New workflow"
                    onTriggered: root._openNewDialog()
                }
                WfMenuItem {
                    text: "+ New folder…"
                    onTriggered: newFolderDialog.open()
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

                    // Tree view of folders with expand/collapse
                    // chevrons. Uses `visibleTree` (flattened render
                    // order) so the Repeater stays a flat list while
                    // the data model is hierarchical.
                    Repeater {
                        model: root.visibleTree
                        delegate: folderTreeRowComp
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

            // Folder breadcrumb — only visible when a specific
            // folder is selected. Sits above the grid so the user
            // can see (and click out of) the active folder. Treat
            // the currentFolder name as a "/"-separated path so the
            // row is ready for nested-folder support without a
            // schema change here.
            Item {
                id: folderCrumb
                anchors.left: folderRail.visible ? folderRail.right : parent.left
                anchors.top: parent.top
                anchors.right: parent.right
                height: visible ? 40 : 0
                visible: root.workflows.length > 0
                    && root.currentFolder !== ""
                    && root.currentFolder !== "__top__"

                readonly property var crumbSegments: {
                    if (!visible) return []
                    return root.currentFolder.split("/").filter(s => s.length > 0)
                }

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 24
                    spacing: 6

                    Text {
                        text: "All workflows"
                        color: rootCrumbArea.containsMouse ? Theme.accent : Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.Medium
                        anchors.verticalCenter: parent.verticalCenter
                        MouseArea {
                            id: rootCrumbArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.currentFolder = ""
                        }
                    }

                    Repeater {
                        model: folderCrumb.crumbSegments
                        delegate: Row {
                            spacing: 6
                            readonly property bool isLast:
                                model.index === folderCrumb.crumbSegments.length - 1
                            readonly property string targetPath:
                                folderCrumb.crumbSegments.slice(0, model.index + 1).join("/")

                            Text {
                                text: "›"
                                color: Theme.text3
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontSm
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: modelData
                                color: parent.isLast
                                    ? Theme.text
                                    : (segArea.containsMouse ? Theme.accent : Theme.text3)
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontSm
                                font.weight: parent.isLast ? Font.DemiBold : Font.Medium
                                anchors.verticalCenter: parent.verticalCenter
                                MouseArea {
                                    id: segArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: !parent.parent.isLast
                                    cursorShape: enabled
                                        ? Qt.PointingHandCursor
                                        : Qt.ArrowCursor
                                    onClicked:
                                        root.currentFolder = parent.parent.targetPath
                                }
                            }
                        }
                    }
                }
            }

            // "This folder is empty" message — shown when the user
            // is filtering to a folder (or top-level) that has no
            // workflows, but the overall library is non-empty so the
            // big EmptyState welcome is wrong.
            Item {
                anchors.left: folderRail.visible ? folderRail.right : parent.left
                anchors.top: folderCrumb.visible ? folderCrumb.bottom : parent.top
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                visible: root.workflows.length > 0
                    && root.filtered.length === 0

                Column {
                    anchors.centerIn: parent
                    spacing: 6
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.searchQuery && root.searchQuery.length > 0
                            ? "No workflows match “" + root.searchQuery + "”."
                            : "This folder is empty."
                        color: Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.searchQuery && root.searchQuery.length > 0
                            ? "Try a different search term, or pick another folder."
                            : "Drag a workflow card here, or use “↳ Move to…” in select mode."
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                    }
                }
            }

            ScrollView {
                id: gridScroll
                anchors.left: folderRail.visible ? folderRail.right : parent.left
                anchors.top: folderCrumb.visible ? folderCrumb.bottom : parent.top
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                visible: root.workflows.length > 0 && root.filtered.length > 0
                contentWidth: availableWidth
                clip: true

                Item {
                    width: parent.width
                    // Always fill at least the viewport height so a
                    // right-click in the empty area below the last
                    // row still lands on this Item (and hits the
                    // canvas-context MouseArea sitting at z:-1 below
                    // the loader). Without this, the content Item
                    // shrinks to its cards' footprint and clicks
                    // outside fall through to the page background.
                    height: Math.max(
                        variantLoader.item ? variantLoader.item.height + 48 : 200,
                        gridScroll.availableHeight)

                    // Empty-canvas right-click → "+ New workflow" /
                    // "+ New folder…" menu. Sits behind the loader so
                    // card clicks reach the cards first; only clicks
                    // OUTSIDE any card fall through to here.
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.RightButton
                        z: -1
                        onClicked: canvasContextMenu.popup()
                    }

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
                            folders: root.visibleFolders
                            workflows: root.filtered
                            allWorkflows: root.workflows
                            selectMode: root.selectMode
                            selectedIds: root.selectedIds
                            onOpenWorkflow: (id) => root.openWorkflow(id)
                            onOpenFolder: (path) => { root.currentFolder = path }
                            onDeleteRequested: (id) => root._askDelete(id)
                            onDuplicateRequested: (id) => libCtrl.duplicate(id)
                            onPublishRequested: (id) => root._openPublish(id)
                            onToggleSelected: (id) => root._toggleSelected(id)
                        }
                    }
                    Component {
                        id: listComp
                        LibraryList {
                            width: variantLoader.width
                            folders: root.visibleFolders
                            workflows: root.filtered
                            selectMode: root.selectMode
                            selectedIds: root.selectedIds
                            onOpenWorkflow: (id) => root.openWorkflow(id)
                            onOpenFolder: (path) => { root.currentFolder = path }
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

    // Tree-row component for nested folder rendering. Delegate
    // shape: { name, fullPath, depth, hasChildren, expanded }. The
    // sidebar Repeater uses `visibleTree` (flattened render order
    // honouring expanded state) so rows are still a flat list while
    // the data model is hierarchical.
    Component {
        id: folderTreeRowComp
        Rectangle {
            readonly property string fullPath: modelData.fullPath
            readonly property string folderName: modelData.name
            readonly property int rowDepth: modelData.depth
            readonly property bool rowHasChildren: modelData.hasChildren
            readonly property bool rowExpanded: modelData.expanded
            readonly property int rowCount: {
                const list = root.workflows || []
                return list.filter(w => w.folder === fullPath).length
            }
            readonly property bool isCurrent: root.currentFolder === fullPath

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            height: 30
            radius: 6
            color: treeDrop.containsDrag
                ? Theme.accentWash(0.28)
                : (isCurrent
                    ? Theme.accentWash(0.16)
                    : (treeRowArea.containsMouse ? Theme.surface2 : "transparent"))
            border.color: treeDrop.containsDrag ? Theme.accent : "transparent"
            border.width: treeDrop.containsDrag ? 1 : 0
            Behavior on color { ColorAnimation { duration: Theme.durFast } }

            // Whole-row click → activate the folder filter.
            // Declared FIRST so its hit area is visually behind the
            // chevron's MouseArea (sibling order = z order in QML);
            // the chevron's click handler intercepts its own clicks
            // and the rest of the row falls through here.
            MouseArea {
                id: treeRowArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.currentFolder = fullPath
            }

            Row {
                anchors.fill: parent
                anchors.leftMargin: 8 + rowDepth * 14
                anchors.rightMargin: 10
                spacing: 6

                // Chevron — clickable separately from the row label
                // so toggling expansion doesn't change the active
                // folder filter. Spacer of equal width when the
                // folder has no children, so labels line up across
                // siblings at the same depth.
                Item {
                    width: 14
                    height: 14
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                        anchors.centerIn: parent
                        visible: rowHasChildren
                        text: rowExpanded ? "▾" : "▸"
                        color: chevronArea.containsMouse ? Theme.accent : Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: 11
                        font.weight: Font.Bold
                    }
                    MouseArea {
                        id: chevronArea
                        anchors.fill: parent
                        anchors.margins: -3
                        hoverEnabled: true
                        enabled: rowHasChildren
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: root._setExpanded(fullPath, !rowExpanded)
                    }
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "▢"
                    color: isCurrent ? Theme.accent : Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: 12
                    width: 14
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: folderName
                    color: isCurrent ? Theme.accent : Theme.text
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    font.weight: isCurrent ? Font.DemiBold : Font.Medium
                    elide: Text.ElideRight
                    width: parent.width - 14 - 6 - 14 - 6 - treeCountLabel.width - 6
                }
                Text {
                    id: treeCountLabel
                    anchors.verticalCenter: parent.verticalCenter
                    text: rowCount > 0 ? rowCount.toString() : ""
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: Theme.fontXs
                }
            }

            DropArea {
                id: treeDrop
                anchors.fill: parent
                keys: ["wflow/workflow-id"]
                onDropped: (drop) => {
                    const src = drop.source
                    const id = (src && src.wf) ? src.wf.id : ""
                    if (!id) return
                    libCtrl.set_folder(id, fullPath)
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
            // workflows in it. Name can contain `/` for nested
            // folders ("dev/test" creates workflows/dev/test/).
            // Don't auto-navigate into the new folder — the user
            // might want to drag a workflow into it next without
            // losing their place.
            libCtrl.create_folder(name)
            // Force a refresh: the bridge's set_workflows call
            // doesn't fire `workflowsChanged` when the JSON value is
            // identical (Qt's auto-generated setters dedupe). An
            // empty new folder doesn't change workflows JSON, so
            // the sidebar would stay stale. Re-pull explicitly.
            root._refreshShaped()
            newFolderInput.text = ""
            newFolderDialog.close()
        }

        // Reset whenever the dialog opens. If the user is currently
        // viewing a folder, pre-fill the input with "<currentFolder>/"
        // so creating a sub-folder is one keystroke instead of
        // retyping the whole path.
        onOpened: {
            const cur = root.currentFolder
            if (cur && cur.length > 0 && cur !== "__top__") {
                newFolderInput.text = cur + "/"
                // Cursor at end so the user just types the new
                // segment.
                newFolderInput.cursorPosition = newFolderInput.text.length
            } else {
                newFolderInput.text = ""
            }
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
                    text: "Folders live as a tag on each workflow. Pick a name now and drop any workflow on the folder to move it in."
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
