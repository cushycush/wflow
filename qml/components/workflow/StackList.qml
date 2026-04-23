import QtQuick
import QtQuick.Controls
import Wflow

// Variant 0 — STACK
// The existing vertical ActionRow list. Kept as the baseline.
Column {
    id: root
    property var actions: []
    property int activeStepIndex: -1
    property bool running: false

    spacing: 8

    Repeater {
        model: root.actions
        delegate: ActionRow {
            id: rowItem
            width: parent.width
            index: model.index + 1
            kind: modelData.kind
            summary: modelData.summary
            valueText: modelData.value
            active: (model.index === root.activeStepIndex)

            opacity: 0
            transform: Translate { id: entryT; x: VisualStyle.animatedEntry ? -20 : 0 }
            Component.onCompleted: {
                if (VisualStyle.animatedEntry) {
                    entryTimer.interval = 40 + (model.index * 35)
                    entryTimer.start()
                } else {
                    rowItem.opacity = 1
                    entryT.x = 0
                }
            }
            Timer {
                id: entryTimer
                repeat: false
                onTriggered: {
                    entryT.x = 0
                    rowItem.opacity = 1
                }
            }
            Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
        }
    }

    // Add-action affordance
    Rectangle {
        width: parent.width
        height: 48
        radius: Theme.radiusMd
        color: addArea.containsMouse ? Theme.surface2 : "transparent"
        border.color: Theme.lineSoft
        border.width: 1

        MouseArea {
            id: addArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
        }

        Row {
            anchors.centerIn: parent
            spacing: 10
            Rectangle {
                width: 22; height: 22; radius: 11
                color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.15)
                anchors.verticalCenter: parent.verticalCenter
                Text {
                    anchors.centerIn: parent
                    text: "+"
                    color: Theme.accent
                    font.family: Theme.familyBody
                    font.pixelSize: 16
                    font.weight: Font.Bold
                }
            }
            Text {
                text: "Add action"
                color: Theme.text2
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                font.weight: Font.Medium
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
