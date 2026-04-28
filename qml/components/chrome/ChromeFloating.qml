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
    // empty-state placeholder. `docTitles` is a parallel { source:
    // title } map kept out of openDocs so resolving a workflow's
    // title from disk doesn't mutate openDocs and force the
    // WorkflowPage Repeater to recreate every delegate.
    property var openDocs: []
    property var docTitles: ({})
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
        // Workflow slot: a tab strip at the top-left + a Repeater of
        // WorkflowPage instances below. Only the active tab is
        // visible; the others stay alive so per-doc state (crumb,
        // selection, save state, the wfCtrl bridge) survives a tab
        // switch.
        Item {
            id: workflowSlot

            // Folder-style tab strip across the top-left of the
            // editor area. Each tab has rounded top corners, flat
            // bottom, and the active tab fills with the page surface
            // colour so it visually merges with the document below
            // — IDE / browser tab convention. A 1px hairline along
            // the bottom of the strip + the tab itself sit at the
            // same y so the active tab "punches through" the line.
            Rectangle {
                id: tabBar
                visible: root.openDocs.length > 0
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 36
                color: Theme.bg

                // Bottom hairline that the active tab covers so the
                // tab and document body read as one continuous
                // surface.
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 1
                    color: Theme.line
                }

                Row {
                    id: tabRow
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: 16
                    spacing: 2

                    Repeater {
                        model: root.openDocs
                        delegate: Rectangle {
                            id: tabChip
                            readonly property bool isActive: model.index === root.activeDocIndex
                            readonly property bool isFragment: modelData.kind === "fragment"
                            readonly property color tabAccent:
                                isFragment ? Theme.catUse : Theme.accent
                            // Tab body shape: rounded top corners,
                            // flat bottom. The Rectangle's `radius`
                            // applies to all corners, so we layer two
                            // rectangles — a rounded one on top + a
                            // square one anchored to the bottom half
                            // — to get only the top corners curved.
                            width: chipRow.implicitWidth + 28
                            height: 32
                            color: "transparent"

                            // Outer rounded rectangle — the visible
                            // surface. We give it a height taller
                            // than the tab + clip the bottom with
                            // the inner square so only the top
                            // corners read as rounded.
                            Rectangle {
                                anchors.fill: parent
                                anchors.bottomMargin: -6
                                radius: 6
                                color: tabChip.isActive
                                    ? Theme.surface
                                    : (chipArea.containsMouse
                                        ? Theme.surface2
                                        : Qt.rgba(Theme.surface.r, Theme.surface.g,
                                                  Theme.surface.b, 0.55))
                                border.color: tabChip.isActive
                                    ? Theme.line
                                    : Theme.lineSoft
                                border.width: 1
                                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                                // Active-tab indicator: 2px accent
                                // strip along the top edge so the
                                // current doc reads from across the
                                // window. Color-coded by kind
                                // (amber for workflow, violet for
                                // fragment) — same idea as VS Code's
                                // dirty / git-decoration tints.
                                Rectangle {
                                    visible: tabChip.isActive
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.leftMargin: 1
                                    anchors.rightMargin: 1
                                    anchors.topMargin: 1
                                    height: 2
                                    radius: 1
                                    color: tabChip.tabAccent
                                }
                            }

                            // Whole-chip click → activate the doc.
                            // Declared first so it's visually behind
                            // the close button; the close MouseArea
                            // intercepts its own clicks by sibling
                            // order.
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
                                    text: root.docTitles[modelData.source] || modelData.source
                                    color: tabChip.isActive ? Theme.text : Theme.text2
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontSm
                                    font.weight: tabChip.isActive ? Font.DemiBold : Font.Medium
                                    elide: Text.ElideRight
                                    anchors.verticalCenter: parent.verticalCenter
                                }
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

            Item {
                id: pageHost
                anchors.top: tabBar.visible ? tabBar.bottom : parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom

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
                        // Sync the resolved title up so the tab strip
                        // shows "[demo] navigation test" instead of
                        // the raw workflow id. Skip the placeholder
                        // default so a transient reload doesn't
                        // overwrite a meaningful title.
                        onTitleChanged: {
                            const t = page.title
                            if (t && t !== "Untitled workflow") {
                                root.docTitleResolved(model.index, t)
                            }
                        }
                    }
                }

                // Empty-state placeholder for the case where the user
                // navigated to "workflow" but no tabs are open.
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

            // Editor entry only appears when at least one doc is
            // open — gives the user a way back to the editor from
            // any page without having to re-pick a workflow from
            // the library. The label carries the open-doc count so
            // it reads as a stateful tab, not just nav.
            Repeater {
                model: {
                    const out = [{ id: "library", label: "Library" }]
                    if (Theme.showExplore) out.push({ id: "explore", label: "Explore" })
                    if ((root.openDocs || []).length > 0) {
                        out.push({
                            id: "workflow",
                            label: "Editor (" + root.openDocs.length + ")"
                        })
                    }
                    out.push({ id: "record", label: "Record" })
                    return out
                }
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

                // Sun icon — Unicode glyph reads fine at this size.
                Text {
                    anchors.centerIn: parent
                    visible: Theme.mode === "light"
                    text: "☀"
                    color: Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: 16
                    font.weight: Font.Bold
                }

                // Moon — composed from two overlapping circles so we
                // get a real crescent shape instead of the wispy
                // outlined Unicode glyph (☾) that's hard to read at
                // small sizes. The "carve" rectangle uses the
                // button's hover/idle background colour so the
                // crescent appears subtractive against the chrome.
                Item {
                    visible: Theme.mode === "dark"
                    anchors.centerIn: parent
                    width: 14
                    height: 14

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: Theme.text2
                    }
                    Rectangle {
                        x: parent.width * 0.32
                        y: -1
                        width: parent.width
                        height: parent.height
                        radius: width / 2
                        color: themeArea.containsMouse ? Theme.surface2 : Theme.surface
                    }
                }

                // Auto-mode — half-filled circle indicating "follow
                // system". Same composition trick as the moon but
                // with a vertical edge so it reads as half-light /
                // half-dark.
                Item {
                    visible: Theme.mode === "auto"
                    anchors.centerIn: parent
                    width: 14
                    height: 14

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: Theme.text2
                    }
                    Rectangle {
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width / 2
                        color: themeArea.containsMouse ? Theme.surface2 : Theme.surface
                    }
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

    // (Top-center floating tab strip removed — tabs now live in
    // their natural top-left position inside the workflow slot,
    // just above the page body.)
}
