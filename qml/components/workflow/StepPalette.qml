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

    // Three category rows: Input (the wdotool primitives), Effect (out-
    // of-process side effects), and Flow (control structures). Each
    // row is its own labelled strip — keeping them separated makes
    // the palette scan as a structural map of the language rather
    // than a flat blob of buttons.
    readonly property var _categories: [
        { label: "Input",  kinds: [
            { kind: "key",       label: "Key"      },
            { kind: "type",      label: "Type"     },
            { kind: "click",     label: "Click"    },
            { kind: "move",      label: "Move"     },
            { kind: "scroll",    label: "Scroll"   }
        ]},
        // `note` removed — per-step comments live on each step's
        // `note` field, surfaced as a Comment textfield in the
        // inspector. Standalone Action::Note steps in legacy files
        // still render via the canvas annotation path.
        { label: "Effect", kinds: [
            { kind: "focus",     label: "Focus"    },
            { kind: "wait",      label: "Wait"     },
            { kind: "shell",     label: "Shell"    },
            { kind: "notify",    label: "Notify"   },
            { kind: "clipboard", label: "Clipbd"   }
        ]},
        { label: "Flow",   kinds: [
            { kind: "when",      label: "When"     },
            { kind: "unless",    label: "Unless"   },
            { kind: "repeat",    label: "Repeat"   },
            { kind: "use",       label: "Use"      }
        ]}
    ]

    implicitHeight: tray.height
    implicitWidth: tray.width

    Rectangle {
        id: tray
        anchors.centerIn: parent
        width: trayCol.implicitWidth + 24
        height: trayCol.implicitHeight + 16
        radius: 18
        color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.94)
        border.color: Theme.lineSoft
        border.width: 1

        Column {
            id: trayCol
            anchors.centerIn: parent
            spacing: 4

            Repeater {
                model: root._categories
                delegate: Row {
                    spacing: 4

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontXs
                        font.weight: Font.Bold
                        font.letterSpacing: 1.0
                        width: 48
                        rightPadding: 4
                    }

                    Repeater {
                        model: modelData.kinds
                        delegate: Rectangle {
                            id: chip
                            width: 60
                            height: 32
                            anchors.verticalCenter: parent.verticalCenter
                            radius: 16
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
                                    size: 16
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
                                // Hold the press for the entire drag; the
                                // canvas's pan DragHandler would otherwise
                                // steal the gesture once motion crossed its
                                // threshold and the user would end up
                                // panning the canvas instead of dropping a
                                // chip on it.
                                preventStealing: true
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
    }
}
