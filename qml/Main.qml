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
    property string currentWorkflowId: ""

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
        currentWorkflowId: root.currentWorkflowId
        onNavigate: (page) => { root.currentPage = page; if (page !== "workflow") root.currentWorkflowId = "" }
        onOpenWorkflow: (id) => { root.currentWorkflowId = id; root.currentPage = "workflow" }
        onNewWorkflow: { root.currentWorkflowId = "new-draft"; root.currentPage = "workflow" }
        onRecordRequested: root.currentPage = "record"
    }
}
