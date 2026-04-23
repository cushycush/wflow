import QtQuick
import QtQuick.Controls
import Wflow

// The featured / editor's pick card for Explore. Adapts the old HeroGrid hero
// concept to the community context.
Rectangle {
    id: root
    property var wf
    signal activated(string id)

    // Editorial override: wf.heroPalette can pin the hero tint to a curator-
    // picked palette so the featured slot feels editorial week-to-week rather
    // than locked to whatever the workflow's first-kind color happens to be.
    readonly property color catColor: {
        if (wf && wf.heroPalette) {
            const pals = ({
                "amber":  Theme.accent,
                "purple": Theme.catKey,
                "blue":   Theme.catType,
                "green":  Theme.catClick,
                "teal":   Theme.catClip,
                "pink":   Theme.catNotify,
                "orange": Theme.catShell,
                "gold":   Theme.catFocus
            })
            if (pals[wf.heroPalette]) return pals[wf.heroPalette]
        }
        const k = wf && wf.kinds && wf.kinds.length > 0 ? wf.kinds[0] : "wait"
        const t = ({
            "key": Theme.catKey, "type": Theme.catType, "click": Theme.catClick,
            "move": Theme.catMove, "scroll": Theme.catScroll, "focus": Theme.catFocus,
            "wait": Theme.catWait, "shell": Theme.catShell, "notify": Theme.catNotify,
            "clipboard": Theme.catClip, "note": Theme.catNote
        })
        return t[k] || Theme.catWait
    }

    height: 180
    radius: Theme.radiusLg
    color: Qt.rgba(catColor.r, catColor.g, catColor.b, heroArea.containsMouse ? 0.18 : 0.12)
    border.color: Qt.rgba(catColor.r, catColor.g, catColor.b, 0.45)
    border.width: 1
    Behavior on color { ColorAnimation { duration: Theme.durFast } }

    MouseArea {
        id: heroArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (root.wf) root.activated(root.wf.id)
    }

    Row {
        anchors.fill: parent
        anchors.margins: 28
        spacing: 24

        CategoryIcon {
            kind: root.wf && root.wf.kinds && root.wf.kinds.length > 0 ? root.wf.kinds[0] : "wait"
            size: 72
            hovered: heroArea.containsMouse
            anchors.verticalCenter: parent.verticalCenter
        }

        Column {
            width: parent.width - 72 - 24 - importBtn.width - 24
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Row {
                spacing: 10

                Text {
                    text: "EDITOR'S PICK"
                    color: root.catColor
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
                    text: root.wf ? (root.wf.category || "uncategorized").toUpperCase() : ""
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 10
                    font.letterSpacing: 0.9
                    anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle {
                    width: 3; height: 3; radius: 1.5
                    color: Theme.text3
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: root.wf ? (root.wf.imports + " imports") : ""
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 10
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Text {
                text: root.wf ? root.wf.title : ""
                color: Theme.text
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontXl
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                width: parent.width
            }
            Text {
                text: root.wf ? (root.wf.subtitle + "  ·  by @" + root.wf.author) : ""
                color: Theme.text2
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontBase
                elide: Text.ElideRight
                width: parent.width
            }

            Row {
                spacing: 6
                Repeater {
                    model: root.wf ? (root.wf.kinds || []) : []
                    delegate: CategoryIcon {
                        kind: modelData
                        size: 22
                        hovered: false
                    }
                }
            }
        }

        Button {
            id: importBtn
            text: "Import →"
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
            onClicked: if (root.wf) root.activated(root.wf.id)
        }
    }
}
