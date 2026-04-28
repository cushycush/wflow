import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Wflow

ApplicationWindow {
    id: root
    width: 1280
    height: 800
    minimumWidth: 880
    minimumHeight: 560
    visible: true
    title: "wflow"
    color: Theme.bg

    property string currentPage: "library"        // "library" | "explore" | "workflow" | "record"

    // Open documents — one per tab in the workflow editor. Each
    // entry is `{ kind, source, title }`:
    //   kind   = "workflow" | "fragment"
    //   source = workflow id (kind==workflow) or absolute file path
    //            (kind==fragment)
    //   title  = display label for the tab
    // The empty array means no editor tabs are open; opening a
    // workflow from Library appends (or activates an existing
    // matching tab) and switches to currentPage="workflow".
    property var openDocs: []
    property int activeDocIndex: -1

    readonly property var activeDoc:
        (activeDocIndex >= 0 && activeDocIndex < openDocs.length)
            ? openDocs[activeDocIndex] : null

    function _findDocIndex(kind, source) {
        for (let i = 0; i < openDocs.length; ++i) {
            const d = openDocs[i]
            if (d.kind === kind && d.source === source) return i
        }
        return -1
    }

    function openWorkflowDoc(id) {
        const existing = _findDocIndex("workflow", id)
        if (existing >= 0) {
            activeDocIndex = existing
        } else {
            const next = openDocs.slice()
            next.push({ kind: "workflow", source: id, title: id })
            openDocs = next
            activeDocIndex = next.length - 1
        }
        currentPage = "workflow"
    }

    function openFragmentDoc(path, displayName) {
        const existing = _findDocIndex("fragment", path)
        if (existing >= 0) {
            activeDocIndex = existing
        } else {
            const next = openDocs.slice()
            next.push({
                kind: "fragment",
                source: path,
                title: displayName || path.split("/").pop()
            })
            openDocs = next
            activeDocIndex = next.length - 1
        }
        currentPage = "workflow"
    }

    function closeDoc(index) {
        if (index < 0 || index >= openDocs.length) return
        const next = openDocs.slice()
        next.splice(index, 1)
        openDocs = next
        if (next.length === 0) {
            activeDocIndex = -1
            currentPage = "library"
        } else if (activeDocIndex >= next.length) {
            activeDocIndex = next.length - 1
        } else if (activeDocIndex > index) {
            activeDocIndex = activeDocIndex - 1
        }
    }

    function activateDoc(index) {
        if (index < 0 || index >= openDocs.length) return
        activeDocIndex = index
        currentPage = "workflow"
    }

    function _setDocTitle(index, title) {
        if (index < 0 || index >= openDocs.length) return
        if (!title || title.length === 0) return
        if (openDocs[index].title === title) return
        const next = openDocs.slice()
        next[index] = Object.assign({}, next[index], { title: title })
        openDocs = next
    }

    font.family: Theme.familyBody
    font.pixelSize: Theme.fontBase

    // Segmented pickers in each page header are the primary control; these
    // shortcuts are for keyboard users.
    Shortcut { sequence: "Ctrl+,"; onActivated: LibraryLayout.cycle() }
    Shortcut { sequence: "Ctrl+."; onActivated: Theme.cycleMode() }
    // Ctrl+N follows the current nav-pill order. Editor is no longer
    // a top-level page (you drill in from Library), so the shortcut
    // list mirrors the pill — Library, optional Explore, Record.
    Shortcut { sequence: "Ctrl+1"; onActivated: root.currentPage = "library" }
    Shortcut { sequence: "Ctrl+2"
        onActivated: root.currentPage = Theme.showExplore ? "explore" : "record"
    }
    Shortcut { sequence: "Ctrl+3"
        enabled: Theme.showExplore
        onActivated: root.currentPage = "record"
    }

    ChromeFloating {
        anchors.fill: parent
        currentPage: root.currentPage
        openDocs: root.openDocs
        activeDocIndex: root.activeDocIndex
        onNavigate: (page) => {
            root.currentPage = page
            // Don't clobber openDocs on nav — switching to Library
            // and back should preserve open tabs. Only the
            // activeDocIndex matters for which tab is rendered.
        }
        onOpenWorkflow: (id) => root.openWorkflowDoc(id)
        onOpenFragment: (path, name) => root.openFragmentDoc(path, name)
        onNewWorkflow: root.openWorkflowDoc("new-draft")
        onActivateDoc: (index) => root.activateDoc(index)
        onCloseDoc: (index) => root.closeDoc(index)
        onDocTitleResolved: (index, title) => root._setDocTitle(index, title)
        onRecordRequested: root.currentPage = "record"
    }
}
