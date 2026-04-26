import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Wflow

// Chrome variant 4 — FLOATING
// No chrome. Content fills the window. A floating pill in the top-center
// handles navigation. Each page carries its own "+ New workflow" /
// "Save" / run-style affordances in its header — no global FAB.
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

            // Editor isn't a top-level tab — it's a nested view you
            // reach by clicking a workflow in Library, with a back
            // arrow on the page itself. Keeping it as a tab
            // produced an empty-state page when the user landed
            // there without a selection, which had no useful
            // affordances.
            Repeater {
                model: Theme.showExplore
                    ? [
                        { id: "library",  label: "Library" },
                        { id: "explore",  label: "Explore" },
                        { id: "record",   label: "Record" }
                      ]
                    : [
                        { id: "library",  label: "Library" },
                        { id: "record",   label: "Record" }
                      ]
                delegate: Rectangle {
                    id: tab
                    readonly property bool isActive: modelData.id === root.currentPage
                    // Record gets the err (red) accent across all tab
                    // states so it reads like a record button rather
                    // than just another nav entry. Library / Explore
                    // stay on the warm amber accent.
                    readonly property bool isRecord: modelData.id === "record"
                    readonly property color tabAccent: isRecord ? Theme.err : Theme.accent
                    width: lbl.implicitWidth + 24
                    height: 32
                    radius: 16
                    anchors.verticalCenter: parent.verticalCenter
                    color: isActive
                        ? Qt.rgba(tabAccent.r, tabAccent.g, tabAccent.b, 0.18)
                        : (tabArea.containsMouse ? Theme.surface2 : "transparent")
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                    activeFocusOnTab: true
                    Keys.onReturnPressed: root.navigate(modelData.id)
                    Keys.onEnterPressed:  root.navigate(modelData.id)
                    Keys.onSpacePressed:  root.navigate(modelData.id)
                    FocusRing { }

                    Text {
                        id: lbl
                        anchors.centerIn: parent
                        text: modelData.label
                        color: tab.isRecord
                            ? (tab.isActive ? Theme.err : Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.85))
                            : (tab.isActive ? Theme.accent : Theme.text2)
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: tab.isActive ? Font.DemiBold : Font.Medium
                    }
                    MouseArea {
                        id: tabArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            tab.forceActiveFocus()
                            root.navigate(modelData.id)
                        }
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

}
