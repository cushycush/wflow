import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Wflow

// Floating-pill chrome. Pages fill the window; per-page headers carry
// their own action buttons.
Item {
    id: root
    property string currentPage: "library"
    // docTitles is parallel to openDocs so updating a title doesn't
    // mutate openDocs and force the WorkflowPage Repeater to rebuild.
    property var openDocs: []
    property var docTitles: ({})
    property int activeDocIndex: -1

    signal navigate(string page)
    signal openWorkflow(string id)
    signal openFragment(string path, string displayName)
    signal newWorkflow()
    signal activateDoc(int index)
    signal closeDoc(int index)
    signal docTitleResolved(int index, string title)
    signal recordRequested()
    signal showTutorRequested()

    StackLayout {
        id: pageStack
        anchors.fill: parent
        currentIndex: root.currentPage === "library" ? 0 :
                      root.currentPage === "explore" ? 1 :
                      root.currentPage === "workflow" ? 2 :
                      root.currentPage === "record" ? 3 : 4

        // Listening to currentPage (not currentIndex) so the animation
        // runs on the first nav too, where the index doesn't change.
        Connections {
            target: root
            function onCurrentPageChanged() { pageEnterAnim.restart() }
        }
        ParallelAnimation {
            id: pageEnterAnim
            NumberAnimation {
                target: pageStack
                property: "opacity"
                from: 0; to: 1
                duration: Theme.dur(Theme.durBase)
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: pageStack
                property: "scale"
                from: 0.985; to: 1.0
                duration: Theme.dur(Theme.durBase)
                easing.type: Easing.OutCubic
            }
        }

        LibraryPage {
            id: libraryPageInst
            onNewWorkflow: root.newWorkflow()
            onOpenWorkflow: (id) => root.openWorkflow(id)
            onRecordRequested: root.recordRequested()
        }
        ExplorePage {
            onOpenWorkflow: (id) => root.openWorkflow(id)
        }
        // Repeater keeps inactive WorkflowPages alive so per-doc state
        // (crumb, selection, save, wfCtrl) survives a tab switch.
        Item {
            id: workflowSlot

            Rectangle {
                id: tabBar
                visible: root.openDocs.length > 0
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 36
                color: Theme.bg

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
                            // Top-rounded only: outer Rectangle is taller
                            // than the chip and tucks past the bottom edge.
                            width: chipRow.implicitWidth + 28
                            height: 32
                            color: "transparent"

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

                            // First in source order so the close button
                            // (later sibling) intercepts its own clicks.
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
                        // Skip "Untitled workflow" so a transient reload
                        // doesn't overwrite a real title.
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
            id: recordPageInst
            onOpenWorkflow: (id) => root.openWorkflow(id)
        }
        SettingsPage {
            id: settingsPageInst
            onClose: root.navigate("library")
            onShowTutorRequested: root.showTutorRequested()
        }
    }

    // Exported for the first-run TutorialCoach so it can point at
    // the floating pill as a single coach-mark target.
    property alias pillContainer: navPill
    property alias settingsButton: settingsBtn
    property alias libraryPage: libraryPageInst
    property alias workflowSlot: workflowSlot
    property alias recordPage: recordPageInst

    // Floating nav bar, rounded-rect style matching the editor's
    Rectangle {
        id: navPill
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

            Rectangle {
                width: 28; height: 28; radius: Theme.radiusSm
                color: Theme.accent
                anchors.verticalCenter: parent.verticalCenter
                Text {
                    anchors.centerIn: parent
                    text: "w"
                    color: Theme.accentText
                    font.family: Theme.familyDisplay
                    font.pixelSize: 15
                    font.weight: Font.Bold
                }
            }

            Item { width: 6; height: 1 }

            Repeater {
                model: {
                    const out = []
                    if (Theme.showExplore) out.push({ id: "explore", label: "Explore" })
                    out.push({ id: "library", label: "Library" })
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
                    // Record uses err so it reads like a record button.
                    readonly property bool isRecord: modelData.id === "record"
                    readonly property color tabAccent: isRecord ? Theme.err : Theme.accent
                    readonly property color tabFg: tab.isRecord
                        ? (tab.isActive ? Theme.err : Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.85))
                        : (tab.isActive ? Theme.accent : Theme.text2)
                    width: tabContent.implicitWidth + 20
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

                    Row {
                        id: tabContent
                        anchors.centerIn: parent
                        spacing: 7

                        // Drawn from primitives so glyphs render the same
                        // across systems regardless of font fallback.
                        Item {
                            id: tabIcon
                            width: 12
                            height: 12
                            anchors.verticalCenter: parent.verticalCenter

                            Item {
                                visible: modelData.id === "library"
                                anchors.fill: parent
                                Rectangle { x: 0; y: 0; width: 5; height: 5; radius: 1; color: tab.tabFg }
                                Rectangle { x: 7; y: 0; width: 5; height: 5; radius: 1; color: tab.tabFg }
                                Rectangle { x: 0; y: 7; width: 5; height: 5; radius: 1; color: tab.tabFg }
                                Rectangle { x: 7; y: 7; width: 5; height: 5; radius: 1; color: tab.tabFg }
                            }

                            Item {
                                visible: modelData.id === "explore"
                                anchors.fill: parent
                                Rectangle {
                                    x: 0; y: 0; width: 9; height: 9
                                    radius: 4.5
                                    color: "transparent"
                                    border.color: tab.tabFg
                                    border.width: 1.5
                                }
                                Rectangle {
                                    x: 7.5; y: 9.5
                                    width: 4; height: 1.5
                                    radius: 0.75
                                    color: tab.tabFg
                                    transform: Rotation {
                                        origin.x: 0
                                        origin.y: 0.75
                                        angle: -45
                                    }
                                }
                            }

                            Item {
                                visible: modelData.id === "workflow"
                                anchors.fill: parent
                                Rectangle {
                                    x: 0; y: 4.5; width: 4; height: 4
                                    radius: 2
                                    color: tab.tabFg
                                }
                                Rectangle {
                                    x: 4; y: 5.75; width: 4; height: 1.5
                                    color: tab.tabFg
                                }
                                Rectangle {
                                    x: 8; y: 4.5; width: 4; height: 4
                                    radius: 2
                                    color: tab.tabFg
                                }
                            }

                            Rectangle {
                                visible: modelData.id === "record"
                                anchors.centerIn: parent
                                width: 8; height: 8
                                radius: 4
                                color: tab.tabFg
                            }
                        }

                        Text {
                            id: lbl
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.label
                            color: tab.tabFg
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            font.weight: tab.isActive ? Font.DemiBold : Font.Medium
                        }
                    }

                    MouseArea {
                        id: tabArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        // No forceActiveFocus: it triggers the FocusRing
                        // which competes with the accent-wash fill.
                        onClicked: root.navigate(modelData.id)
                    }
                }
            }

            Item { width: 2; height: 1 }

            // (Theme cycle button moved to Settings, Ctrl+. still cycles
            // for keyboard users; the chrome no longer carries it now
            // that there's a real Settings page.)

            Rectangle {
                id: settingsBtn
                width: 24; height: 24; radius: Theme.radiusSm
                anchors.verticalCenter: parent.verticalCenter
                readonly property bool isActive: root.currentPage === "settings"
                readonly property color iconColor: isActive ? Theme.accent : Theme.text2
                color: isActive
                    ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                    : (settingsArea.containsMouse ? Theme.surface2 : "transparent")
                Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                // Built from primitives because Unicode ⚙ is too heavy.
                Item {
                    anchors.centerIn: parent
                    width: 13
                    height: 13

                    Repeater {
                        model: 8
                        delegate: Rectangle {
                            width: 2
                            height: 3
                            radius: 1
                            color: settingsBtn.iconColor
                            x: 6.5 - width / 2
                                + Math.cos(index * Math.PI / 4 - Math.PI / 2) * 5.25
                            y: 6.5 - height / 2
                                + Math.sin(index * Math.PI / 4 - Math.PI / 2) * 5.25
                            transform: Rotation {
                                origin.x: 1
                                origin.y: 1.5
                                angle: index * 45
                            }
                        }
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: 9
                        height: 9
                        radius: width / 2
                        color: settingsBtn.iconColor
                    }
                    // Cut-out tracks the button bg so the donut hub
                    // always matches what's behind it.
                    Rectangle {
                        anchors.centerIn: parent
                        width: 3
                        height: 3
                        radius: width / 2
                        color: settingsBtn.isActive
                            ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                            : (settingsArea.containsMouse ? Theme.surface2 : Theme.surface)
                    }
                }

                MouseArea {
                    id: settingsArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.navigate("settings")
                    ToolTip.visible: containsMouse
                    ToolTip.delay: 400
                    ToolTip.text: "Settings"
                }
            }
        }
    }

}
