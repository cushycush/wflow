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
    // Ctrl+N follows the current nav-pill order — the Explore tab only
    // appears when Theme.showExplore is on, so the shortcut list shifts too.
    Shortcut { sequence: "Ctrl+1"; onActivated: root.currentPage = "library" }
    Shortcut { sequence: "Ctrl+2"
        onActivated: root.currentPage = Theme.showExplore ? "explore" : "workflow"
    }
    Shortcut { sequence: "Ctrl+3"
        onActivated: root.currentPage = Theme.showExplore ? "workflow" : "record"
    }
    Shortcut { sequence: "Ctrl+4"
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
