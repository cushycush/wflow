import QtQuick
import QtQuick.Controls
import Wflow

// Local library of user-authored workflows. Two layouts (Grid / List) the
// user picks via the switcher in the header. No featured hero here — that
// concept belongs in Explore, not on someone's own workspace.
Item {
    id: root
    signal newWorkflow()
    signal openWorkflow(string id)
    signal recordRequested()

    property var workflows: [
        { id: "p1", title: "Open dev setup",      subtitle: "launch editor, terminal, focus firefox",
          steps: 12, lastRun: "yesterday",     runs: 47,
          kinds: ["key", "shell", "type", "focus"] },
        { id: "p2", title: "Screenshot to clip",  subtitle: "region grab → wl-copy",
          steps: 2,  lastRun: "2h ago",        runs: 112,
          kinds: ["shell", "clipboard"] },
        { id: "p3", title: "VPN on",              subtitle: "toggle the work vpn",
          steps: 3,  lastRun: "3d ago",        runs: 8,
          kinds: ["shell", "notify"] },
        { id: "p4", title: "Close the day",       subtitle: "commit, push, lock screen",
          steps: 6,  lastRun: "never",         runs: 0,
          kinds: ["shell", "notify", "key"] },
        { id: "p5", title: "Morning standup",     subtitle: "open slack, zoom, project notes",
          steps: 5,  lastRun: "this morning",  runs: 94,
          kinds: ["shell", "focus", "type"] },
        { id: "p6", title: "Review PRs",          subtitle: "fetch branches, open github tabs",
          steps: 8,  lastRun: "5h ago",        runs: 23,
          kinds: ["shell", "key", "type", "click"] },
        { id: "p7", title: "Deep focus",          subtitle: "DND on, music, hide dock",
          steps: 4,  lastRun: "12d ago",       runs: 6,
          kinds: ["notify", "shell", "focus"] },
        { id: "p8", title: "Clipboard to file",   subtitle: "paste clipboard into scratch.md",
          steps: 3,  lastRun: "never",         runs: 0,
          kinds: ["clipboard", "shell", "note"] }
    ]

    Column {
        anchors.fill: parent
        spacing: 0

        TopBar {
            id: tb
            width: parent.width
            title: "Library"
            subtitle: root.workflows.length + " workflows"

            LibraryLayoutSwitcher { anchors.verticalCenter: parent.verticalCenter }

            Button {
                text: "+ New workflow"
                topPadding: 8; bottomPadding: 8
                leftPadding: 14; rightPadding: 14
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
            Button {
                text: "● Record"
                topPadding: 8; bottomPadding: 8
                leftPadding: 14; rightPadding: 14
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
        }

        ScrollView {
            width: parent.width
            height: parent.height - tb.height
            contentWidth: availableWidth
            clip: true

            Item {
                width: parent.width
                height: variantLoader.item ? variantLoader.item.height + 48 : 200

                Loader {
                    id: variantLoader
                    x: 24; y: 24
                    width: parent.width - 48

                    sourceComponent: LibraryLayout.variant === 0 ? gridComp : listComp

                    opacity: 0
                    Component.onCompleted: opacity = 1
                    onSourceComponentChanged: {
                        opacity = 0
                        fadeIn.restart()
                    }
                    Timer {
                        id: fadeIn
                        interval: 30
                        onTriggered: variantLoader.opacity = 1
                    }
                    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                }

                Component {
                    id: gridComp
                    LibraryGrid {
                        width: variantLoader.width
                        workflows: root.workflows
                        onOpenWorkflow: (id) => root.openWorkflow(id)
                    }
                }
                Component {
                    id: listComp
                    LibraryList {
                        width: variantLoader.width
                        workflows: root.workflows
                        onOpenWorkflow: (id) => root.openWorkflow(id)
                    }
                }
            }
        }
    }
}
