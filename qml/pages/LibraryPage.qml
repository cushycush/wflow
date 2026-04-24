import QtQuick
import QtQuick.Controls
import Wflow

// Local library of user-authored workflows.
//
// Data flows through LibraryController (a cxx-qt QObject registered by the
// Rust side). It reads $XDG_CONFIG_HOME/wflow/workflows/*.kdl on construction
// and exposes the list as a JSON string we parse here. QML components want
// camelCased keys + a few display-only fields, so we shape the summaries
// into a `workflows` array that the grid/list delegates already understand.
Item {
    id: root
    signal newWorkflow()
    signal openWorkflow(string id)
    signal recordRequested()

    LibraryController { id: libCtrl }

    function _humanizeTs(iso) {
        if (!iso) return "never"
        const then = new Date(iso)
        const diffMs = Date.now() - then.getTime()
        if (isNaN(diffMs) || diffMs < 0) return then.toLocaleDateString()
        const mins = Math.floor(diffMs / 60000)
        if (mins < 1)  return "just now"
        if (mins < 60) return mins + "m ago"
        const hrs  = Math.floor(mins / 60)
        if (hrs  < 24) return hrs + "h ago"
        const days = Math.floor(hrs / 24)
        if (days === 1) return "yesterday"
        if (days < 14)  return days + "d ago"
        return then.toLocaleDateString()
    }

    function _shape(rawList) {
        const out = []
        for (const wf of rawList) {
            out.push({
                id:       wf.id,
                title:    wf.title,
                subtitle: wf.subtitle && wf.subtitle.length > 0 ? wf.subtitle : "",
                steps:    wf.steps || 0,
                lastRun:  root._humanizeTs(wf.last_run),
                runs:     0,                 // real counter lands with run-history persistence
                kinds:    wf.kinds || []
            })
        }
        return out
    }

    property var workflows: []

    function _refreshShaped() {
        try {
            const raw = JSON.parse(libCtrl.workflows || "[]")
            root.workflows = root._shape(raw)
        } catch (e) {
            root.workflows = []
        }
    }

    Component.onCompleted: _refreshShaped()
    Connections {
        target: libCtrl
        function onWorkflowsChanged() { root._refreshShaped() }
    }

    // Drag-to-reorder is local-only until the bridge owns a user-ordered
    // list. For now splicing the shaped array gives the ListView its
    // move/displaced transitions; the on-disk order is by modified-time.
    function moveWorkflow(from, to) {
        if (from === to) return
        const a = root.workflows.slice()
        const [item] = a.splice(from, 1)
        a.splice(to, 0, item)
        root.workflows = a
    }

    Column {
        anchors.fill: parent
        spacing: 0

        TopBar {
            id: tb
            width: parent.width
            title: "Library"
            subtitle: root.workflows.length === 1
                ? "1 workflow"
                : root.workflows.length + " workflows"

            LibraryLayoutSwitcher {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.workflows.length > 0
            }

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
                    color: Theme.accentText
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.DemiBold
                }
                onClicked: {
                    const id = libCtrl.new_workflow("Untitled")
                    if (id && id.length > 0) root.openWorkflow(id)
                    else root.newWorkflow()
                }
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

        Item {
            width: parent.width
            height: parent.height - tb.height

            // Empty state — wired for the first-run case where the
            // workflows directory is empty. No reshuffling required: the
            // + New workflow button already sits in the top bar, and this
            // CTA points at it.
            EmptyState {
                anchors.fill: parent
                visible: root.workflows.length === 0
                title: "No workflows yet"
                description: "Create a new workflow by hand, or hit Record and wflow will transcribe a sequence of keys, clicks, and commands into one."
                actionLabel: "● Record a workflow"
                onActionClicked: root.recordRequested()
            }

            ScrollView {
                anchors.fill: parent
                visible: root.workflows.length > 0
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
                            onDeleteRequested: (id) => libCtrl.remove(id)
                            onDuplicateRequested: (id) => libCtrl.duplicate(id)
                        }
                    }
                    Component {
                        id: listComp
                        LibraryList {
                            width: variantLoader.width
                            workflows: root.workflows
                            onOpenWorkflow: (id) => root.openWorkflow(id)
                            onReorderRequested: (from, to) => root.moveWorkflow(from, to)
                            onDeleteRequested: (id) => libCtrl.remove(id)
                            onDuplicateRequested: (id) => libCtrl.duplicate(id)
                        }
                    }
                }
            }
        }
    }
}
