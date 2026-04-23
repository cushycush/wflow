import QtQuick
import QtQuick.Controls
import Wflow

// Variant 2 — MOSAIC
// Masonry-ish. Cards vary in height based on index pattern.
// First card in each row is taller and shows a preview of all its action icons.
Flow {
    id: root
    property var workflows: []
    signal openWorkflow(string id)

    spacing: 14

    Repeater {
        model: root.workflows
        delegate: Rectangle {
            id: tile
            readonly property bool isHero: (index % 5) === 0
            readonly property color catColor: {
                const k = modelData.kinds && modelData.kinds.length > 0 ? modelData.kinds[0] : "wait"
                const t = ({
                    "key": Theme.catKey, "type": Theme.catType, "click": Theme.catClick,
                    "move": Theme.catMove, "scroll": Theme.catScroll, "focus": Theme.catFocus,
                    "wait": Theme.catWait, "shell": Theme.catShell, "notify": Theme.catNotify,
                    "clipboard": Theme.catClip, "note": Theme.catNote
                })
                return t[k] || Theme.catWait
            }

            width: isHero ? (root.width - 14) * 0.52 : (root.width - 14 * 2) / 3 - 4
            height: isHero ? 220 : 140
            radius: Theme.radiusMd
            color: {
                const c = catColor
                return Qt.rgba(c.r, c.g, c.b, tileArea.containsMouse ? 0.14 : 0.07)
            }
            border.color: tileArea.containsMouse
                ? Qt.rgba(catColor.r, catColor.g, catColor.b, 0.5)
                : Theme.lineSoft
            border.width: 1
            Behavior on color { ColorAnimation { duration: Theme.durFast } }

            MouseArea {
                id: tileArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openWorkflow(modelData.id)
            }

            Column {
                anchors.fill: parent
                anchors.margins: tile.isHero ? 22 : 16
                spacing: 10

                // Top row: icon + meta
                Row {
                    width: parent.width
                    spacing: 12

                    CategoryIcon {
                        kind: modelData.kinds && modelData.kinds.length > 0 ? modelData.kinds[0] : "wait"
                        size: tile.isHero ? 48 : 32
                        hovered: tileArea.containsMouse
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - (tile.isHero ? 48 : 32) - 12
                        spacing: 2

                        Text {
                            text: modelData.title
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: tile.isHero ? Theme.fontLg : Theme.fontMd
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            width: parent.width
                        }
                        Text {
                            text: modelData.steps + " steps · " + modelData.lastRun
                            color: Theme.text3
                            font.family: Theme.familyMono
                            font.pixelSize: 10
                        }
                    }
                }

                Text {
                    text: modelData.subtitle
                    color: Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: tile.isHero ? Theme.fontBase : Theme.fontSm
                    lineHeight: 1.35
                    wrapMode: Text.Wrap
                    elide: Text.ElideRight
                    maximumLineCount: tile.isHero ? 3 : 2
                    width: parent.width
                }

                // Hero: show the action sequence as icons
                Row {
                    visible: tile.isHero
                    spacing: 6
                    Repeater {
                        model: modelData.kinds || []
                        delegate: CategoryIcon {
                            kind: modelData
                            size: 26
                            hovered: false
                        }
                    }
                }
            }
        }
    }
}
