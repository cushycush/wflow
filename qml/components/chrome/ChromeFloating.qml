import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Wflow

// Chrome variant 4 — FLOATING
// No chrome. Content fills the window. A floating pill in the top-center
// handles navigation, and a floating + button in the bottom-right creates.
Item {
    id: root
    property string currentPage: "library"
    property string currentWorkflowId: ""

    signal navigate(string page)
    signal openWorkflow(string id)
    signal newWorkflow()
    signal recordRequested()

    // Full-bleed pages
    StackLayout {
        anchors.fill: parent
        currentIndex: root.currentPage === "library" ? 0 :
                      root.currentPage === "explore" ? 1 :
                      root.currentPage === "workflow" ? 2 : 3

        LibraryPage {
            onNewWorkflow: root.newWorkflow()
            onOpenWorkflow: (id) => root.openWorkflow(id)
            onRecordRequested: root.recordRequested()
        }
        ExplorePage {
            onOpenWorkflow: (id) => root.openWorkflow(id)
        }
        WorkflowPage {
            workflowId: root.currentWorkflowId
            onBackRequested: root.navigate("library")
        }
        RecordPage {
            onOpenWorkflow: (id) => root.openWorkflow(id)
        }
    }

    // Floating nav pill
    Rectangle {
        anchors.top: parent.top
        anchors.topMargin: 18
        anchors.horizontalCenter: parent.horizontalCenter
        width: pillRow.implicitWidth + 20
        height: 48
        radius: 24
        color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.95)
        border.color: Theme.line
        border.width: 1

        Row {
            id: pillRow
            anchors.centerIn: parent
            spacing: 4

            // Logo circle
            Rectangle {
                width: 32; height: 32; radius: 16
                color: Theme.accent
                anchors.verticalCenter: parent.verticalCenter
                Text {
                    anchors.centerIn: parent
                    text: "w"
                    color: Theme.accentText
                    font.family: Theme.familyBody
                    font.pixelSize: 16
                    font.weight: Font.Bold
                }
            }

            Item { width: 6; height: 1 }

            Repeater {
                model: [
                    { id: "library",  label: "Library" },
                    { id: "explore",  label: "Explore" },
                    { id: "workflow", label: "Editor" },
                    { id: "record",   label: "Record" }
                ]
                delegate: Rectangle {
                    readonly property bool isActive: modelData.id === root.currentPage
                    width: lbl.implicitWidth + 24
                    height: 32
                    radius: 16
                    anchors.verticalCenter: parent.verticalCenter
                    color: isActive
                        ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                        : (tabArea.containsMouse ? Theme.surface2 : "transparent")
                    Behavior on color { ColorAnimation { duration: Theme.durFast } }

                    Text {
                        id: lbl
                        anchors.centerIn: parent
                        text: modelData.label
                        color: isActive ? Theme.accent : Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: isActive ? Font.DemiBold : Font.Medium
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

            Item { width: 2; height: 1 }

            // Theme mode cycle: auto → light → dark → auto.
            // Icon reflects the current mode, not the resolved theme, so the
            // user can tell whether they've pinned it.
            Rectangle {
                id: themeBtn
                width: 32; height: 32; radius: 16
                anchors.verticalCenter: parent.verticalCenter
                color: themeArea.containsMouse ? Theme.surface2 : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.durFast } }

                Text {
                    anchors.centerIn: parent
                    text: Theme.mode === "light" ? "☀" : Theme.mode === "dark" ? "☾" : "◐"
                    color: Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: 14
                }

                MouseArea {
                    id: themeArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Theme.cycleMode()
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: Theme.mode === "auto"
                        ? "Theme: follow system"
                        : Theme.mode === "light" ? "Theme: light" : "Theme: dark"
                }
            }
        }
    }

    // Floating "+ new" FAB bottom-right. Hidden on Explore because the user
    // isn't authoring from a catalog view, and the drawer's Import CTA needs
    // the space.
    Rectangle {
        visible: root.currentPage !== "explore"
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.margins: 24
        width: fabRow.implicitWidth + 28
        height: 56
        radius: 28
        color: fabArea.containsMouse ? Theme.accentHi : Theme.accent
        Behavior on color { ColorAnimation { duration: Theme.durFast } }

        Row {
            id: fabRow
            anchors.centerIn: parent
            spacing: 10
            Text {
                text: "+"
                color: Theme.accentText
                font.family: Theme.familyBody
                font.pixelSize: 22
                font.weight: Font.Bold
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: "New workflow"
                color: Theme.accentText
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                font.weight: Font.DemiBold
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        MouseArea {
            id: fabArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.newWorkflow()
        }
    }
}
