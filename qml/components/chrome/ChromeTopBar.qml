import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Wflow

// Chrome variant 2 — TOP BAR
// No sidebar. Horizontal top bar with logo, tab triplet, and primary actions.
// Content fills full width below.
Item {
    id: root
    property string currentPage: "library"
    property string currentWorkflowId: ""

    signal navigate(string page)
    signal openWorkflow(string id)
    signal newWorkflow()
    signal recordRequested()

    Column {
        anchors.fill: parent
        spacing: 0

        // The top bar
        Rectangle {
            width: parent.width
            height: 60
            color: Theme.surface

            Rectangle {
                width: parent.width; height: 1
                anchors.bottom: parent.bottom
                color: Theme.line
            }

            Row {
                anchors.fill: parent
                anchors.leftMargin: 24
                anchors.rightMargin: 24
                spacing: 24

                // Logo
                Row {
                    spacing: 10
                    anchors.verticalCenter: parent.verticalCenter

                    Rectangle { width: 22; height: 22; radius: 5; color: Theme.accent; anchors.verticalCenter: parent.verticalCenter }
                    Text {
                        text: "wflow"
                        color: Theme.text
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Bold
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Rectangle { width: 1; height: 28; color: Theme.lineSoft; anchors.verticalCenter: parent.verticalCenter }

                // Tabs
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Repeater {
                        model: [
                            { id: "library",  label: "Library" },
                            { id: "workflow", label: "Editor" },
                            { id: "record",   label: "Record" }
                        ]
                        delegate: Rectangle {
                            readonly property bool isActive: modelData.id === root.currentPage
                            width: tabText.implicitWidth + 28
                            height: 36
                            radius: 6
                            color: isActive
                                ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.15)
                                : (tabArea.containsMouse ? Theme.surface2 : "transparent")
                            Behavior on color { ColorAnimation { duration: Theme.durFast } }

                            Text {
                                id: tabText
                                anchors.centerIn: parent
                                text: modelData.label
                                color: isActive ? Theme.accent : Theme.text2
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontSm
                                font.weight: isActive ? Font.DemiBold : Font.Medium
                            }

                            // Bottom accent when active
                            Rectangle {
                                visible: isActive
                                anchors.bottom: parent.bottom
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.bottomMargin: -2
                                width: 28; height: 2; radius: 1
                                color: Theme.accent
                            }

                            MouseArea {
                                id: tabArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.navigate(modelData.id)
                            }
                        }
                    }
                }

                // Spacer
                Item {
                    width: parent.width - x - actions.width - 24
                    height: 1
                }

                // Right-side actions
                Row {
                    id: actions
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    Button {
                        text: "● Record"
                        topPadding: 7; bottomPadding: 7; leftPadding: 14; rightPadding: 14
                        background: Rectangle {
                            radius: Theme.radiusSm
                            color: parent.hovered ? Theme.surface3 : Theme.surface2
                            border.color: Theme.line
                            border.width: 1
                        }
                        contentItem: Text {
                            text: parent.text
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            font.weight: Font.Medium
                        }
                        onClicked: root.recordRequested()
                    }
                    Button {
                        text: "+ New"
                        topPadding: 7; bottomPadding: 7; leftPadding: 14; rightPadding: 14
                        background: Rectangle {
                            radius: Theme.radiusSm
                            color: parent.hovered ? Theme.accentHi : Theme.accent
                        }
                        contentItem: Text {
                            text: parent.text
                            color: "#1a1208"
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            font.weight: Font.DemiBold
                        }
                        onClicked: root.newWorkflow()
                    }
                }
            }
        }

        // Content (full width)
        StackLayout {
            width: parent.width
            height: parent.height - 60
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
