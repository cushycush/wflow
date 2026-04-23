import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Wflow

// Chrome variant 0 — SIDEBAR
// The original layout: full 240px sidebar, pages in a StackLayout to the right.
Item {
    id: root
    property string currentPage: "library"
    property string currentWorkflowId: ""

    signal navigate(string page)
    signal openWorkflow(string id)
    signal newWorkflow()
    signal recordRequested()

    RowLayout {
        anchors.fill: parent
        spacing: 0

        Sidebar {
            Layout.preferredWidth: 240
            Layout.fillHeight: true
            currentPage: root.currentPage
            currentWorkflowId: root.currentWorkflowId
            onNavigate: (page) => root.navigate(page)
            onOpenWorkflow: (id) => root.openWorkflow(id)
            onNewWorkflow: root.newWorkflow()
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: root.currentPage === "library" ? 0 :
                          root.currentPage === "workflow" ? 1 : 2

            LibraryPage {
                onNewWorkflow: root.newWorkflow()
                onOpenWorkflow: (id) => root.openWorkflow(id)
                onRecordRequested: root.recordRequested()
            }
            WorkflowPage {
                workflowId: root.currentWorkflowId
                onBackRequested: root.navigate("library")
            }
            RecordPage {}
        }
    }
}
