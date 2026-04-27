import QtQuick
import QtQuick.Controls
import Wflow

// Floating action palette for the canvas. Each chip is draggable —
// the WorkflowCanvas's DropArea picks up the mime payload and asks
// the page to add a step at the drop point.
//
// Lives bottom-center on the canvas as a translucent tray. The same
// kinds are also available from the rail's "+ Add step" menu, so
// keyboard-only users keep parity.
Item {
    id: root

    // Mirrors the rail's pickable kinds plus the flow-control entries.
    // The flow-control kinds (when, unless, repeat) currently round-
    // trip via KDL — adding them inserts a sensibly-defaulted block
    // that the user can flesh out via the inspector or KDL edit.
    readonly property var _kinds: [
        { kind: "key",       label: "Key"      },
        { kind: "type",      label: "Type"     },
        { kind: "click",     label: "Click"    },
        { kind: "move",      label: "Move"     },
        { kind: "scroll",    label: "Scroll"   },
        { kind: "focus",     label: "Focus"    },
        { kind: "wait",      label: "Wait"     },
        { kind: "shell",     label: "Shell"    },
        { kind: "notify",    label: "Notify"   },
        { kind: "clipboard", label: "Clipbd"   },
        { kind: "note",      label: "Note"     }
    ]

    implicitHeight: tray.height
    implicitWidth: tray.width

    Rectangle {
        id: tray
        anchors.centerIn: parent
        width: trayRow.implicitWidth + 20
        height: 52
        radius: 26
        color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.94)
        border.color: Theme.lineSoft
        border.width: 1

        Row {
            id: trayRow
            anchors.centerIn: parent
            spacing: 4

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Drag onto canvas:"
                color: Theme.text3
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontXs
                rightPadding: 4
            }

            Repeater {
                model: root._kinds
                delegate: Item {
                    id: chipItem
                    width: 56
                    height: 36
                    anchors.verticalCenter: parent.verticalCenter

                    // Drag payload — picked up by the canvas's DropArea.
                    Drag.active: chipArea.drag.active
                    Drag.hotSpot.x: width / 2
                    Drag.hotSpot.y: height / 2
                    Drag.dragType: Drag.Automatic
                    Drag.keys: ["wflow/kind"]
                    Drag.mimeData: { "wflow/kind": modelData.kind }

                    Rectangle {
                        id: chip
                        anchors.fill: parent
                        radius: 18
                        color: chipArea.drag.active
                            ? Theme.accentWash(0.22)
                            : (chipArea.containsMouse ? Theme.surface2 : Theme.surface)
                        border.color: chipArea.drag.active ? Theme.accent : Theme.lineSoft
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

                        Row {
                            anchors.centerIn: parent
                            spacing: 6
                            CategoryIcon {
                                kind: modelData.kind
                                size: 18
                                hovered: chipArea.containsMouse
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.label
                                color: Theme.text2
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontXs
                                font.weight: Font.Medium
                            }
                        }
                    }

                    MouseArea {
                        id: chipArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                        drag.target: chipItem
                        drag.threshold: 2
                        onReleased: {
                            // Hand the drop to whoever's listening; if no
                            // DropArea picks it up the chip animates back
                            // to its tray slot.
                            chipItem.Drag.drop()
                            chipItem.x = 0
                            chipItem.y = 0
                        }
                    }

                    // Snap back to the tray when no drop landed.
                    Behavior on x {
                        enabled: !chipArea.drag.active
                        NumberAnimation { duration: Theme.dur(Theme.durBase); easing.type: Theme.easingStd }
                    }
                    Behavior on y {
                        enabled: !chipArea.drag.active
                        NumberAnimation { duration: Theme.dur(Theme.durBase); easing.type: Theme.easingStd }
                    }
                }
            }
        }
    }
}
