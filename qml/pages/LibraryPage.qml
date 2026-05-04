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

    property alias topBar: tb
    property alias folderRail: folderRail

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
                id:        wf.id,
                title:     wf.title,
                subtitle:  wf.subtitle && wf.subtitle.length > 0 ? wf.subtitle : "",
                steps:     wf.steps || 0,
                lastRun:   root._humanizeTs(wf.last_run),
                runs:      0,                 // landing with run-history persistence
                kinds:     wf.kinds || [],
                folder:    wf.folder || "",
                _modified: wf.modified || "",
                _lastRun:  wf.last_run || ""
            })
        }
        return out
    }

    property var workflows: []
    property string searchQuery: ""
    // "" = all folders. "__top__" = workflows with no folder (default
    // so a deeply-foldered library doesn't dump everything into one page).
    property string currentFolder: "__top__"
    // "recent" | "name" | "last_run".
    property string sortBy: "recent"
    property var folderList: []

    // Resets per session; full-path keyed.
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
        // Includes the path itself so direct children appear too.
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

    readonly property var visibleTree: {
        const paths = (root.folderList || []).slice().sort()
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

    // Direct children of the current folder. "__top__" / "" means
    // top-level; "a" means direct children of "a/".
    readonly property var visibleFolders: {
        const q = (root.searchQuery || "").trim().toLowerCase()
        const fld = root.currentFolder
        const isTopLevel = fld === "" || fld === "__top__"
        const prefix = isTopLevel ? "" : (fld + "/")
        const out = []
        const seen = {}
        for (const full of root.folderList || []) {
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
            // Never-run goes last.
            out = out.slice().sort((a, b) => {
                if (!a._lastRun && !b._lastRun) return 0
                if (!a._lastRun) return 1
                if (!b._lastRun) return -1
                return b._lastRun.localeCompare(a._lastRun)
            })
        } else {
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
            publishDialog.lastError = "signed out, sign in again to publish"
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
        }

        Shortcut {
            sequence: "Escape"
            enabled: root.visible && root.selectMode
            onActivated: root._exitSelect()
        }

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

            // Folders are derived from workflows.toml meta; there's no
            // separate folders file, so creation only happens as a
            // side-effect of moving a workflow into a name.
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
                        model: root.visibleTree
                        delegate: folderTreeRowComp
                    }

                    // No on-disk folder; "create" stashes the name and
                    // a right-click drops the first workflow in.
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

            // currentFolder is "/"-separated, ready for nested folders.
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
                    // Fill at least the viewport so right-clicks below
                    // the last card still hit the canvasContext MouseArea.
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

    // Delegate shape: { id, label, glyph }. id is "" / "__top__" /
    // any user folder name.
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
            // Hide the Top-level row unless it's needed (current filter
            // or it has contents) so the rail doesn't carry dead rows.
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

            // "All workflows" (id == "") doesn't accept drops; it's a
            // view filter, not a bucket. Read the id off drop.source
            // because Drag.mimeData via Drag.Internal didn't reliably
            // surface in getDataAsString.
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

    // Delegate shape: { name, fullPath, depth, hasChildren, expanded }.
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

            // First in source order so the chevron's MouseArea (later
            // sibling) sits above and intercepts its own clicks.
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

                // Always reserves 14px so labels line up across
                // siblings of the same depth even when no chevron.
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

    // Folders only exist as long as a workflow references them; this
    // is a select-then-name flow that drops a workflow into the new name.
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
            // Don't auto-navigate into the new folder, the user
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

        // Pre-fill with "<currentFolder>/" so creating a sub-folder
        // is one keystroke instead of retyping the path.
        onOpened: {
            const cur = root.currentFolder
            if (cur && cur.length > 0 && cur !== "__top__") {
                newFolderInput.text = cur + "/"
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
