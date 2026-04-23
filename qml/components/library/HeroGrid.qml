import QtQuick
import QtQuick.Controls
import Wflow

// Variant 3 — HERO + GRID
// Big featured card on top (first workflow), compact grid below for the rest.
Column {
    id: root
    property var workflows: []
    signal openWorkflow(string id)
    signal runWorkflow(string id)

    spacing: 16

    // ===== Hero =====
    Rectangle {
        id: hero
        readonly property var wf: root.workflows.length > 0 ? root.workflows[0] : null
        readonly property color catColor: {
            if (!wf) return Theme.accent
            const k = wf.kinds && wf.kinds.length > 0 ? wf.kinds[0] : "wait"
            const t = ({
                "key": Theme.catKey, "type": Theme.catType, "click": Theme.catClick,
                "move": Theme.catMove, "scroll": Theme.catScroll, "focus": Theme.catFocus,
                "wait": Theme.catWait, "shell": Theme.catShell, "notify": Theme.catNotify,
                "clipboard": Theme.catClip, "note": Theme.catNote
            })
            return t[k] || Theme.catWait
        }

        width: parent.width
        height: 170
        radius: Theme.radiusLg
        visible: wf !== null
        color: {
            const c = catColor
            return Qt.rgba(c.r, c.g, c.b, heroArea.containsMouse ? 0.16 : 0.10)
        }
        border.color: Qt.rgba(catColor.r, catColor.g, catColor.b, 0.42)
        border.width: 1
        Behavior on color { ColorAnimation { duration: Theme.durFast } }

        MouseArea {
            id: heroArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (hero.wf) root.openWorkflow(hero.wf.id)
        }

        Row {
            anchors.fill: parent
            anchors.margins: 28
            spacing: 24

            CategoryIcon {
                kind: hero.wf && hero.wf.kinds && hero.wf.kinds.length > 0 ? hero.wf.kinds[0] : "wait"
                size: 64
                hovered: heroArea.containsMouse
                anchors.verticalCenter: parent.verticalCenter
            }

            Column {
                width: parent.width - 64 - 24 - runBtn.width - 24
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                Row {
                    spacing: 10
                    Text {
                        text: "FEATURED"
                        color: hero.catColor
                        font.family: Theme.familyMono
                        font.pixelSize: 10
                        font.weight: Font.Bold
                        font.letterSpacing: 0.9
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Rectangle {
                        width: 3; height: 3; radius: 1.5
                        color: Theme.text3
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: (hero.wf ? hero.wf.runs : 0) + " runs"
                        color: Theme.text3
                        font.family: Theme.familyMono
                        font.pixelSize: 10
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Text {
                    text: hero.wf ? hero.wf.title : ""
                    color: Theme.text
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                    width: parent.width
                }
                Text {
                    text: hero.wf ? hero.wf.subtitle : ""
                    color: Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontBase
                    lineHeight: 1.3
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    width: parent.width
                }

                Row {
                    spacing: 6
                    Repeater {
                        model: hero.wf ? (hero.wf.kinds || []) : []
                        delegate: CategoryIcon {
                            kind: modelData
                            size: 24
                            hovered: false
                        }
                    }
                }
            }

            Button {
                id: runBtn
                text: "▶ Run"
                anchors.verticalCenter: parent.verticalCenter
                topPadding: 12; bottomPadding: 12
                leftPadding: 20; rightPadding: 20
                background: Rectangle {
                    radius: Theme.radiusSm
                    color: parent.hovered ? Theme.accentHi : Theme.accent
                }
                contentItem: Text {
                    text: parent.text
                    color: "#1a1208"
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.DemiBold
                }
                onClicked: if (hero.wf) root.runWorkflow(hero.wf.id)
            }
        }
    }

    // ===== Grid of the rest =====
    Flow {
        width: parent.width
        spacing: 12

        Repeater {
            model: root.workflows.slice(1)
            delegate: Rectangle {
                id: smallCard
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
                width: (parent.width - 12 * 3) / 4
                height: 108
                radius: Theme.radiusMd
                color: {
                    const c = catColor
                    return Qt.rgba(c.r, c.g, c.b, smArea.containsMouse ? 0.12 : 0.06)
                }
                border.color: smArea.containsMouse
                    ? Qt.rgba(catColor.r, catColor.g, catColor.b, 0.4)
                    : Theme.lineSoft
                border.width: 1
                Behavior on color { ColorAnimation { duration: Theme.durFast } }

                MouseArea {
                    id: smArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openWorkflow(modelData.id)
                }

                Column {
                    anchors.fill: parent
                    anchors.margins: 14
                    spacing: 8

                    Row {
                        spacing: 10
                        width: parent.width

                        CategoryIcon {
                            kind: modelData.kinds && modelData.kinds.length > 0 ? modelData.kinds[0] : "wait"
                            size: 28
                            hovered: smArea.containsMouse
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            text: modelData.title
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            width: parent.width - 28 - 10
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Text {
                        text: modelData.subtitle
                        color: Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontXs
                        lineHeight: 1.3
                        wrapMode: Text.Wrap
                        elide: Text.ElideRight
                        maximumLineCount: 2
                        width: parent.width
                    }

                    Text {
                        text: modelData.steps + " · " + modelData.lastRun
                        color: Theme.text3
                        font.family: Theme.familyMono
                        font.pixelSize: 10
                    }
                }
            }
        }
    }
}
