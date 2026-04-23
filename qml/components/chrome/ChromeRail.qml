import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Wflow

// Chrome variant 1 — RAIL
// Narrow 72px icon-only rail. Pages get maximum horizontal space.
// Tooltip-like hover labels on rail buttons.
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

        Rectangle {
            id: rail
            Layout.preferredWidth: 72
            Layout.fillHeight: true
            color: Theme.surface

            // Right edge hairline
            Rectangle {
                width: 1; height: parent.height
                anchors.right: parent.right
                color: Theme.line
            }

            Column {
                anchors.top: parent.top
                anchors.topMargin: 20
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 10

                // Logo
                Rectangle {
                    width: 36; height: 36; radius: 8
                    color: Theme.accent
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Item { width: 1; height: 16 }

                Repeater {
                    model: [
                        { id: "library",  glyph: "▦", tip: "Library", color: Theme.text2 },
                        { id: "workflow", glyph: "▷", tip: "Editor",  color: Theme.text2 },
                        { id: "record",   glyph: "●", tip: "Record",  color: Theme.err }
                    ]
                    delegate: Rectangle {
                        readonly property bool isActive: modelData.id === root.currentPage
                        width: 48; height: 48; radius: 10
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: isActive
                            ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                            : (btnArea.containsMouse ? Theme.surface2 : "transparent")
                        border.color: isActive ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.45) : "transparent"
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: Theme.durFast } }

                        Text {
                            anchors.centerIn: parent
                            text: modelData.glyph
                            color: isActive ? Theme.accent : modelData.color
                            font.family: Theme.familyBody
                            font.pixelSize: 18
                            font.weight: Font.Bold
                        }

                        MouseArea {
                            id: btnArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.navigate(modelData.id)
                        }
                    }
                }
            }

            // New workflow bottom
            Column {
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 20
                anchors.horizontalCenter: parent.horizontalCenter

                Rectangle {
                    width: 48; height: 48; radius: 24
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: newArea.containsMouse ? Theme.accentHi : Theme.accent
                    Behavior on color { ColorAnimation { duration: Theme.durFast } }

                    Text {
                        anchors.centerIn: parent
                        text: "+"
                        color: "#1a1208"
                        font.family: Theme.familyBody
                        font.pixelSize: 22
                        font.weight: Font.Bold
                    }

                    MouseArea {
                        id: newArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.newWorkflow()
                    }
                }
            }
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
