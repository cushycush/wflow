import QtQuick
import QtQuick.Controls
import Wflow

// Workflow editor. Split layout: step list on the left, inspector on the
// right. Other layouts (Stack / Timeline / Grouped / Cards) are archived
// under qml/components/workflow/_archive — kept in source so we can dust
// them off if the product direction changes.
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
            subtitle: root.subtitle

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
                    text: parent.text; color: Theme.accentText
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

        Item {
            width: parent.width
            height: parent.height - tb.height

            SplitInspector {
                anchors.fill: parent
                anchors.margins: 24
                actions: root.actions
                activeStepIndex: root.activeStepIndex
                running: root.running
            }
        }
    }
}
