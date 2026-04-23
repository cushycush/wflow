import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Wflow

// Chrome variant 3 — HYBRID
// Thin 56px icon rail + a 220px contextual strip that varies by page.
// Slack-style: global nav is the rail, within-page nav is the strip.
Item {
    id: root
    property string currentPage: "library"
    property string currentWorkflowId: ""

    property var workflows: [
        { id: "p1", title: "Open dev setup",      steps: 12 },
        { id: "p2", title: "Screenshot to clip",  steps: 2  },
        { id: "p3", title: "VPN on",              steps: 3  },
        { id: "p4", title: "Close the day",       steps: 6  }
    ]

    signal navigate(string page)
    signal openWorkflow(string id)
    signal newWorkflow()
    signal recordRequested()

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // Thin icon rail
        Rectangle {
            Layout.preferredWidth: 56
            Layout.fillHeight: true
            color: Theme.bg

            Rectangle { width: 1; height: parent.height; anchors.right: parent.right; color: Theme.lineSoft }

            Column {
                anchors.top: parent.top
                anchors.topMargin: 16
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 6

                Rectangle { width: 28; height: 28; radius: 7; color: Theme.accent; anchors.horizontalCenter: parent.horizontalCenter }
                Item { width: 1; height: 12 }

                Repeater {
                    model: [
                        { id: "library",  glyph: "▦" },
                        { id: "workflow", glyph: "▷" },
                        { id: "record",   glyph: "●" }
                    ]
                    delegate: Rectangle {
                        readonly property bool isActive: modelData.id === root.currentPage
                        width: 40; height: 40; radius: 10
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: isActive ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.15) : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text: modelData.glyph
                            color: isActive ? Theme.accent : (modelData.id === "record" ? Theme.err : Theme.text3)
                            font.family: Theme.familyBody
                            font.pixelSize: 16
                            font.weight: Font.Bold
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.navigate(modelData.id)
                        }
                    }
                }
            }
        }

        // Contextual strip
        Rectangle {
            Layout.preferredWidth: 220
            Layout.fillHeight: true
            color: Theme.surface

            Rectangle { width: 1; height: parent.height; anchors.right: parent.right; color: Theme.line }

            Column {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 10

                // Contextual header
                Text {
                    text: root.currentPage === "library" ? "WORKFLOWS"
                         : root.currentPage === "workflow" ? "STEPS"
                         : "RECORDING"
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    font.weight: Font.Bold
                    font.letterSpacing: 1.2
                }

                // Library context: workflow list
                Loader {
                    visible: root.currentPage === "library"
                    width: parent.width
                    sourceComponent: Column {
                        spacing: 2
                        Repeater {
                            model: root.workflows
                            delegate: SidebarWorkflow {
                                width: parent.width
                                title: modelData.title
                                stepCount: modelData.steps
                                selected: modelData.id === root.currentWorkflowId
                                onClicked: root.openWorkflow(modelData.id)
                            }
                        }
                    }
                }

                // Workflow context: step index
                Loader {
                    visible: root.currentPage === "workflow"
                    width: parent.width
                    sourceComponent: Column {
                        spacing: 2
                        Repeater {
                            model: ["Press key", "Wait", "Run shell", "Wait", "Type text",
                                    "Press key", "Run shell", "Wait", "Focus window",
                                    "Press key", "Type text", "Press key"]
                            delegate: Row {
                                width: parent.width
                                height: 28
                                spacing: 10
                                Text {
                                    text: String(index + 1).padStart(2, "0")
                                    color: Theme.text3
                                    font.family: Theme.familyMono
                                    font.pixelSize: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 20
                                }
                                Text {
                                    text: modelData
                                    color: Theme.text2
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontXs
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    width: parent.width - 30
                                }
                            }
                        }
                    }
                }

                // Record context: state hint
                Loader {
                    visible: root.currentPage === "record"
                    width: parent.width
                    sourceComponent: Column {
                        spacing: 8
                        Text {
                            text: "Status"
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: 10
                            font.weight: Font.Bold
                            font.letterSpacing: 1.0
                        }
                        Rectangle {
                            width: parent.width; height: 36; radius: Theme.radiusSm
                            color: Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.1)
                            border.color: Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.3)
                            border.width: 1
                            Row {
                                anchors.centerIn: parent
                                spacing: 8
                                Rectangle {
                                    width: 8; height: 8; radius: 4
                                    color: Theme.err
                                    anchors.verticalCenter: parent.verticalCenter
                                    SequentialAnimation on opacity {
                                        running: true
                                        loops: Animation.Infinite
                                        NumberAnimation { to: 0.2; duration: 500 }
                                        NumberAnimation { to: 1.0; duration: 500 }
                                    }
                                }
                                Text {
                                    text: "ARMED"
                                    color: Theme.err
                                    font.family: Theme.familyMono
                                    font.pixelSize: 11
                                    font.weight: Font.Bold
                                    font.letterSpacing: 1.0
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }
                }
            }
        }

        // Main content
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
