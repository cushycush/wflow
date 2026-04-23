import QtQuick
import QtQuick.Controls
import Wflow

// Variant 4 — TIMELINE
// Sections grouped by recency: Recent, This week, Older, Never.
// Each section: header label + horizontal Flow of chunky pill rows.
Column {
    id: root
    property var workflows: []
    signal openWorkflow(string id)

    spacing: 24

    function bucketOf(lastRun) {
        if (lastRun === "never") return 3
        if (lastRun.indexOf("h ago") !== -1) return 0
        if (lastRun === "this morning" || lastRun === "yesterday") return 0
        if (lastRun.indexOf("d ago") !== -1) {
            const n = parseInt(lastRun, 10)
            if (!isNaN(n) && n <= 3) return 1
            return 2
        }
        return 2
    }

    readonly property var buckets: {
        const b = [[], [], [], []]
        for (let i = 0; i < workflows.length; i++) {
            const w = workflows[i]
            b[bucketOf(w.lastRun)].push(w)
        }
        return b
    }

    readonly property var bucketLabels: ["Today", "This week", "Earlier", "Never run"]

    Repeater {
        model: 4
        delegate: Column {
            visible: root.buckets[modelData].length > 0
            width: root.width
            spacing: 10

            // Section header
            Row {
                spacing: 10
                width: parent.width

                Text {
                    text: root.bucketLabels[modelData].toUpperCase()
                    color: Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: 11
                    font.weight: Font.Bold
                    font.letterSpacing: 1.0
                    anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle {
                    width: 4; height: 4; radius: 2
                    color: Theme.text3
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: root.buckets[modelData].length + (root.buckets[modelData].length === 1 ? " workflow" : " workflows")
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 10
                    anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle {
                    height: 1
                    color: Theme.lineSoft
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.parent.width - x - 8
                }
            }

            // Items — wide pill rows
            Flow {
                width: parent.width
                spacing: 10

                Repeater {
                    model: root.buckets[modelData]
                    delegate: Rectangle {
                        id: pill
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
                        width: Math.max(260, contentRow.implicitWidth + 40)
                        height: 54
                        radius: 27
                        color: pillArea.containsMouse ? Theme.surface2 : Theme.surface
                        border.color: pillArea.containsMouse
                            ? Qt.rgba(catColor.r, catColor.g, catColor.b, 0.5)
                            : Theme.lineSoft
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: Theme.durFast } }

                        MouseArea {
                            id: pillArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.openWorkflow(modelData.id)
                        }

                        Row {
                            id: contentRow
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            spacing: 12

                            CategoryIcon {
                                kind: modelData.kinds && modelData.kinds.length > 0 ? modelData.kinds[0] : "wait"
                                size: 34
                                hovered: pillArea.containsMouse
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2

                                Text {
                                    text: modelData.title
                                    color: Theme.text
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontSm
                                    font.weight: Font.DemiBold
                                }
                                Text {
                                    text: modelData.steps + " · " + modelData.lastRun
                                    color: Theme.text3
                                    font.family: Theme.familyMono
                                    font.pixelSize: 10
                                }
                            }

                            Item { width: 6; height: 1 }
                        }
                    }
                }
            }
        }
    }
}
