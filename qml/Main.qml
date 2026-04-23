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

    property string currentPage: "library"       // "library" | "workflow" | "record"
    property string currentWorkflowId: "p1"

    font.family: Theme.familyBody
    font.pixelSize: Theme.fontBase

    // Segmented pickers in each page header are the primary control; these
    // shortcuts are for keyboard users.
    Shortcut { sequence: "Ctrl+,"; onActivated: LibraryLayout.cycle() }
    Shortcut { sequence: "Ctrl+."; onActivated: Theme.cycleMode() }
    Shortcut { sequence: "Ctrl+1"; onActivated: root.currentPage = "library" }
    Shortcut { sequence: "Ctrl+2"; onActivated: root.currentPage = "explore" }
    Shortcut { sequence: "Ctrl+3"; onActivated: { root.currentWorkflowId = "p1"; root.currentPage = "workflow" } }
    Shortcut { sequence: "Ctrl+4"; onActivated: root.currentPage = "record" }

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
