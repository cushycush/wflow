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

    // Ctrl+; cycles the workflow editor layout (segmented picker also in header).
    Shortcut { sequence: "Ctrl+;"; onActivated: WorkflowLayout.cycle() }

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
