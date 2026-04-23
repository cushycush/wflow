import QtQuick
import QtQuick.Controls
import Wflow

// The 260px sidebar: logo, primary actions, then workflow library list.
Rectangle {
    id: root
    color: Theme.surface
    property string currentWorkflowId: ""
    property string currentPage: "library"  // "library" | "workflow" | "record"

    // Workflow list model (static for now; bridge wires real data later).
    property var workflows: [
        { id: "p1", title: "Open dev setup",      steps: 12 },
        { id: "p2", title: "Screenshot to clip",  steps: 2  },
        { id: "p3", title: "VPN on",              steps: 3  },
        { id: "p4", title: "Close the day",       steps: 6  }
    ]

    signal navigate(string page)
    signal openWorkflow(string id)
    signal newWorkflow()

    // Right-edge hairline
    Rectangle {
        width: 1
        height: parent.height
        anchors.right: parent.right
        color: Theme.line
    }

    Column {
        anchors.fill: parent
        anchors.topMargin: 16
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        spacing: 14

        // ---- Brand ----
        Row {
            spacing: 10
            leftPadding: 4
            height: 24

            Rectangle {
                width: 18
                height: 18
                radius: 4
                color: Theme.accent
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: "wflow"
                color: Theme.text
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontMd
                font.weight: Font.Bold
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        // ---- Primary actions ----
        Column {
            width: parent.width - 24
            spacing: 2

            IconButton {
                width: parent.width
                iconText: "+"
                text: "New workflow"
                iconColor: Theme.accent
                onClicked: root.newWorkflow()
            }
            IconButton {
                width: parent.width
                iconText: "●"
                text: "Record"
                iconColor: Theme.err
                active: root.currentPage === "record"
                onClicked: root.navigate("record")
            }
            IconButton {
                width: parent.width
                iconText: "☰"
                text: "Library"
                active: root.currentPage === "library"
                onClicked: root.navigate("library")
            }
        }

        // ---- Divider ----
        Rectangle {
            width: parent.width - 24
            height: 1
            color: Theme.lineSoft
        }

        // ---- Workflows ----
        Row {
            spacing: 6
            leftPadding: 4
            width: parent.width - 24

            Text {
                text: "WORKFLOWS"
                color: Theme.text3
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontXs
                font.weight: Font.DemiBold
                font.letterSpacing: 0.6
                anchors.verticalCenter: parent.verticalCenter
            }
            Item { width: parent.width - 90; height: 1 }
            Text {
                text: root.workflows.length
                color: Theme.text3
                font.family: Theme.familyMono
                font.pixelSize: Theme.fontXs
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        // ---- Scrollable workflow list ----
        ListView {
            id: workflowList
            width: parent.width - 24
            height: parent.height - y - 14
            clip: true
            spacing: 1
            boundsBehavior: Flickable.StopAtBounds
            model: root.workflows
            delegate: SidebarWorkflow {
                width: workflowList.width
                title: modelData.title
                stepCount: modelData.steps
                selected: modelData.id === root.currentWorkflowId
                onClicked: root.openWorkflow(modelData.id)
            }
        }
    }
}
