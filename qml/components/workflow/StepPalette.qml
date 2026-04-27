import QtQuick
import QtQuick.Controls
import Wflow

// Floating action palette for the canvas. Drag a chip onto the
// canvas to add a step at the drop point.
//
// Drag is handled manually (not Drag/DropArea) so we can show a
// real card-shaped preview ghost in the canvas instead of the
// system drag cursor. The chip's MouseArea forwards press / move
// / release with scene-coordinate points, and the canvas renders
// the ghost itself.
Item {
    id: root
    // The WorkflowCanvas instance to forward drag events to.
    property var canvas: null

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
        width: trayRow.implicitWidth + 24
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
                delegate: Rectangle {
                    id: chip
                    width: 60
                    height: 36
                    anchors.verticalCenter: parent.verticalCenter
                    radius: 18
                    color: chipArea.dragging
                        ? Theme.accentWash(0.22)
                        : (chipArea.containsMouse ? Theme.surface2 : Theme.surface)
                    border.color: chipArea.dragging ? Theme.accent : Theme.lineSoft
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

                    MouseArea {
                        id: chipArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                        property bool dragging: false
                        onPressed: (mouse) => {
                            if (!root.canvas) return
                            const scene = chip.mapToItem(null, mouse.x, mouse.y)
                            dragging = true
                            root.canvas.previewDrag(modelData.kind, scene.x, scene.y)
                        }
                        onPositionChanged: (mouse) => {
                            if (!dragging || !root.canvas) return
                            const scene = chip.mapToItem(null, mouse.x, mouse.y)
                            root.canvas.moveDragPreview(scene.x, scene.y)
                        }
                        onReleased: (mouse) => {
                            if (!dragging) return
                            dragging = false
                            if (root.canvas) {
                                const scene = chip.mapToItem(null, mouse.x, mouse.y)
                                root.canvas.endDragPreview(scene.x, scene.y, true)
                            }
                        }
                        onCanceled: {
                            if (dragging) {
                                dragging = false
                                if (root.canvas) root.canvas.endDragPreview(0, 0, false)
                            }
                        }
                    }
                }
            }
        }
    }
}
