import QtQuick
import QtQuick.Controls
import Wflow

// Workflow editor — the main stage. Swaps between 5 layouts at runtime via
// WorkflowLayout.variant (cycle with Ctrl+;).
Item {
    id: root
    property string workflowId: ""
    property string title: "Open dev setup"
    property string subtitle: "launch editor, terminal, focus firefox"
    property int activeStepIndex: -1
    property bool running: false
    signal backRequested()

    property var actions: [
        { kind: "key",   summary: "Press key chord",      value: "Super + 1" },
        { kind: "wait",  summary: "Wait",                 value: "220 ms" },
        { kind: "shell", summary: "Run shell command",    value: "hyprctl dispatch exec 'kitty'" },
        { kind: "wait",  summary: "Wait",                 value: "350 ms" },
        { kind: "type",  summary: "Type text",            value: "cd ~/projects && ls" },
        { kind: "key",   summary: "Press key chord",      value: "Return" },
        { kind: "shell", summary: "Run shell command",    value: "hyprctl dispatch exec 'firefox'" },
        { kind: "wait",  summary: "Wait",                 value: "600 ms" },
        { kind: "focus", summary: "Focus window",         value: "Firefox" },
        { kind: "key",   summary: "Press key chord",      value: "Ctrl + L" },
        { kind: "type",  summary: "Type text",            value: "hyprland wiki" },
        { kind: "key",   summary: "Press key chord",      value: "Return" }
    ]

    Column {
        anchors.fill: parent
        spacing: 0

        TopBar {
            id: tb
            width: parent.width
            title: root.title
            subtitle: root.subtitle + " · " + WorkflowLayout.label

            Button {
                text: "↗ Share"
                topPadding: 8; bottomPadding: 8; leftPadding: 14; rightPadding: 14
                background: Rectangle {
                    radius: Theme.radiusSm
                    color: parent.hovered ? Theme.surface3 : Theme.surface2
                    border.color: Theme.line
                    border.width: 1
                }
                contentItem: Text {
                    text: parent.text; color: Theme.text
                    font.family: Theme.familyBody; font.pixelSize: Theme.fontSm; font.weight: Font.Medium
                }
            }
            Button {
                id: runBtn
                text: root.running ? "⏸ Running…" : "▶ Run"
                topPadding: 8; bottomPadding: 8; leftPadding: 18; rightPadding: 18
                background: Rectangle {
                    radius: Theme.radiusSm
                    color: parent.hovered ? Theme.accentHi : Theme.accent
                }
                contentItem: Text {
                    text: parent.text; color: "#1a1208"
                    font.family: Theme.familyBody; font.pixelSize: Theme.fontSm; font.weight: Font.DemiBold
                }
                onClicked: {
                    root.running = !root.running
                    if (root.running) playhead.start()
                    else playhead.stop()
                }
            }
        }

        Timer {
            id: playhead
            interval: 700
            repeat: true
            onTriggered: {
                if (root.activeStepIndex >= root.actions.length - 1) {
                    root.activeStepIndex = -1
                    root.running = false
                    stop()
                    return
                }
                root.activeStepIndex += 1
            }
            function start() {
                root.activeStepIndex = 0
                running = true
            }
            function stop() {
                running = false
                root.activeStepIndex = -1
            }
        }

        // Variant host
        ScrollView {
            width: parent.width
            height: parent.height - tb.height
            contentWidth: availableWidth
            clip: true

            Item {
                width: parent.width
                height: variantLoader.item ? variantLoader.item.height + 60 : 200

                Loader {
                    id: variantLoader
                    x: 24; y: 20
                    width: parent.width - 48

                    sourceComponent: {
                        switch (WorkflowLayout.variant) {
                        case 0: return stackComp
                        case 1: return timelineComp
                        case 2: return splitComp
                        case 3: return groupedComp
                        case 4: return cardsComp
                        }
                        return stackComp
                    }

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
                    id: stackComp
                    StackList {
                        width: variantLoader.width
                        actions: root.actions
                        activeStepIndex: root.activeStepIndex
                        running: root.running
                    }
                }
                Component {
                    id: timelineComp
                    HorizontalTimeline {
                        width: variantLoader.width
                        actions: root.actions
                        activeStepIndex: root.activeStepIndex
                        running: root.running
                    }
                }
                Component {
                    id: splitComp
                    SplitInspector {
                        width: variantLoader.width
                        actions: root.actions
                        activeStepIndex: root.activeStepIndex
                        running: root.running
                    }
                }
                Component {
                    id: groupedComp
                    GroupedPhases {
                        width: variantLoader.width
                        actions: root.actions
                        activeStepIndex: root.activeStepIndex
                        running: root.running
                    }
                }
                Component {
                    id: cardsComp
                    CardDeck {
                        width: variantLoader.width
                        actions: root.actions
                        activeStepIndex: root.activeStepIndex
                        running: root.running
                    }
                }
            }
        }
    }
}
