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
    // Multi-tab editor state — owned by Main.qml. Empty array means
    // no editor tabs open; the workflow page area then renders an
    // empty-state placeholder.
    property var openDocs: []
    property int activeDocIndex: -1

    signal navigate(string page)
    signal openWorkflow(string id)
    signal openFragment(string path, string displayName)
    signal newWorkflow()
    signal activateDoc(int index)
    signal closeDoc(int index)
    // Fired when the WorkflowPage at index resolves its title (after
    // the bridge load completes). Main.qml uses this to refresh
    // openDocs[index].title so tab chips show the workflow's real
    // name instead of the raw id we stored at openWorkflowDoc time.
    signal docTitleResolved(int index, string title)
    signal recordRequested()

    // App-wide dot-grid backdrop. Pages render on top; the ones
    // built as transparent Items (Library / Explore / Workflow) let
    // the dots show through their gaps, while RecordPage paints its
    // own ambient background and covers it.
    DotGrid {
        anchors.fill: parent
        z: -1
    }

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
        // Workflow slot: a Repeater of WorkflowPage instances, one per
        // open doc. Only the active tab is visible; the others stay
        // alive so per-doc state (crumb, selection, save state, the
        // wfCtrl bridge) survives a tab switch.
        Item {
            id: workflowSlot

            Repeater {
                model: root.openDocs
                delegate: WorkflowPage {
                    id: page
                    anchors.fill: parent
                    visible: model.index === root.activeDocIndex
                    workflowId: modelData.kind === "workflow" ? modelData.source : ""
                    fragmentPath: modelData.kind === "fragment" ? modelData.source : ""
                    onBackRequested: root.navigate("library")
                    onOpenFragmentRequested: (path, name) => root.openFragment(path, name)
                    onTitleChanged: root.docTitleResolved(model.index, page.title)
                    Component.onCompleted: root.docTitleResolved(model.index, page.title)
                }
            }

            // Empty-state placeholder for the case where the user
            // navigated to "workflow" but no tabs are open. Should be
            // rare given Main.qml only flips currentPage to workflow
            // when a doc is opened, but defensive.
            Item {
                anchors.fill: parent
                visible: root.openDocs.length === 0
                Text {
                    anchors.centerIn: parent
                    text: "No workflow open. Open one from the Library."
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                }
            }
        }
        RecordPage {
            onOpenWorkflow: (id) => root.openWorkflow(id)
        }
    }

    // Floating nav bar — rounded-rect style matching the editor's
    // Tidy / Wires / Zoom pills (radius:Theme.radiusMd container,
    // radius:Theme.radiusSm tabs). Replaced the all-circle pill +
    // round logo + circle theme button with squared-off shapes so
    // the chrome reads consistent with the canvas surface.
    Rectangle {
        anchors.top: parent.top
        anchors.topMargin: 18
        anchors.horizontalCenter: parent.horizontalCenter
        width: pillRow.implicitWidth + 20
        height: 44
        radius: Theme.radiusMd
        color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.95)
        border.color: Theme.line
        border.width: 1

        Row {
            id: pillRow
            anchors.centerIn: parent
            spacing: 4

            // Logo block — rounded square, not a circle.
            Rectangle {
                width: 28; height: 28; radius: Theme.radiusSm
                color: Theme.accent
                anchors.verticalCenter: parent.verticalCenter
                Text {
                    anchors.centerIn: parent
                    text: "w"
                    color: Theme.accentText
                    font.family: Theme.familyBody
                    font.pixelSize: 15
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
                    height: 28
                    radius: Theme.radiusSm
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
                width: 28; height: 28; radius: Theme.radiusSm
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

    // Tab strip — only visible on the workflow page when at least
    // one editor doc is open. Sits below the floating nav pill;
    // each chip shows the doc title plus a close X. Click chip to
    // activate, click X to close. Fragment tabs read-only and
    // styled with a violet tint to distinguish from workflow tabs.
    Rectangle {
        id: tabStrip
        visible: root.currentPage === "workflow" && root.openDocs.length > 0
        anchors.top: parent.top
        anchors.topMargin: 70
        anchors.horizontalCenter: parent.horizontalCenter
        width: tabRow.implicitWidth + 16
        height: tabRow.implicitHeight + 8
        radius: Theme.radiusMd
        color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.95)
        border.color: Theme.line
        border.width: 1

        Row {
            id: tabRow
            anchors.centerIn: parent
            spacing: 4

            Repeater {
                model: root.openDocs
                delegate: Rectangle {
                    id: tabChip
                    readonly property bool isActive: model.index === root.activeDocIndex
                    readonly property bool isFragment: modelData.kind === "fragment"
                    readonly property color tabAccent: isFragment ? Theme.catUse : Theme.accent
                    width: chipRow.implicitWidth + 24
                    height: 28
                    radius: Theme.radiusSm
                    anchors.verticalCenter: parent.verticalCenter
                    color: isActive
                        ? Qt.rgba(tabAccent.r, tabAccent.g, tabAccent.b, 0.18)
                        : (chipArea.containsMouse ? Theme.surface2 : "transparent")
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                    // Whole-chip click → activate the doc. Declared
                    // first so it's visually behind the close button;
                    // the close MouseArea inside chipRow lands on top
                    // by sibling order and intercepts its own clicks.
                    MouseArea {
                        id: chipArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.activateDoc(model.index)
                    }

                    Row {
                        id: chipRow
                        anchors.centerIn: parent
                        spacing: 6

                        // Fragment glyph — small chevron-prefix to
                        // signal "imported into another workflow".
                        Text {
                            visible: tabChip.isFragment
                            text: "↳"
                            color: tabChip.isActive ? tabChip.tabAccent : Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            font.weight: Font.Medium
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            text: modelData.title || modelData.source
                            color: tabChip.isActive ? tabChip.tabAccent : Theme.text2
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            font.weight: tabChip.isActive ? Font.DemiBold : Font.Medium
                            elide: Text.ElideRight
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        // Close button — square so it doesn't visually
                        // collide with the rounded tab chip.
                        Rectangle {
                            width: 16
                            height: 16
                            radius: 3
                            anchors.verticalCenter: parent.verticalCenter
                            color: closeArea.containsMouse
                                ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.18)
                                : "transparent"

                            Text {
                                anchors.centerIn: parent
                                text: "×"
                                color: closeArea.containsMouse
                                    ? Theme.err
                                    : (tabChip.isActive ? Theme.text2 : Theme.text3)
                                font.family: Theme.familyBody
                                font.pixelSize: 14
                                font.weight: Font.Medium
                            }

                            MouseArea {
                                id: closeArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.closeDoc(model.index)
                            }
                        }
                    }
                }
            }
        }
    }
}
