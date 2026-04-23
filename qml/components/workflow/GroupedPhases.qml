import QtQuick
import QtQuick.Controls
import Wflow

// Variant 3 — GROUPED
// Actions bucketed into phases based on kind. Phase headers form visual sections.
// Useful mental model: setup → do → verify.
Column {
    id: root
    property var actions: []
    property int activeStepIndex: -1
    property bool running: false

    spacing: 24

    function phaseOf(kind) {
        if (["shell", "focus", "wait"].indexOf(kind) !== -1) return 0  // SETUP
        if (["key", "type", "click", "move", "scroll", "clipboard"].indexOf(kind) !== -1) return 1  // INPUT
        return 2  // OUTPUT (notify, note, other)
    }
    readonly property var phaseLabels: ["SETUP", "INPUT", "OUTPUT"]
    readonly property var phaseColors: [Theme.catShell, Theme.catKey, Theme.catNotify]

    readonly property var groups: {
        const g = [[], [], []]
        for (let i = 0; i < actions.length; i++) {
            const idx = phaseOf(actions[i].kind)
            g[idx].push({ idx: i, action: actions[i] })
        }
        return g
    }

    Repeater {
        model: 3
        delegate: Column {
            visible: root.groups[modelData].length > 0
            width: root.width
            spacing: 10

            // Phase header
            Row {
                spacing: 12
                width: parent.width

                Rectangle {
                    width: 6; height: 24; radius: 3
                    color: root.phaseColors[modelData]
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: root.phaseLabels[modelData]
                    color: root.phaseColors[modelData]
                    font.family: Theme.familyBody
                    font.pixelSize: 12
                    font.weight: Font.Bold
                    font.letterSpacing: 1.4
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: root.groups[modelData].length + " action" + (root.groups[modelData].length === 1 ? "" : "s")
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 10
                    anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle {
                    width: parent.parent.width - x - 8
                    height: 1
                    color: Theme.lineSoft
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // Rows inside this group
            Column {
                width: parent.width
                spacing: 8

                Repeater {
                    model: root.groups[modelData]
                    delegate: ActionRow {
                        width: parent.width
                        index: modelData.idx + 1
                        kind: modelData.action.kind
                        summary: modelData.action.summary
                        valueText: modelData.action.value
                        active: modelData.idx === root.activeStepIndex
                    }
                }
            }
        }
    }
}
