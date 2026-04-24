import QtQuick
import QtQuick.Controls
import Wflow

// A single community-workflow card, shared by the trending row, the new row,
// and the browse grid on Explore. Shows import count (not stars) as the
// primary social signal.
Rectangle {
    id: root
    property var wf                           // { id, title, subtitle, author, category, kinds, imports, forks, steps, hasShell }
    property real cardW: 280
    property real cardH: 150
    signal activated(string id)

    readonly property color catColor: Theme.catFor(
        wf && wf.kinds && wf.kinds.length > 0 ? wf.kinds[0] : "wait")

    width: cardW
    height: cardH
    radius: Theme.radiusMd
    color: cardArea.containsMouse ? Theme.surface2 : Theme.surface
    border.color: cardArea.containsMouse
        ? Theme.wash(catColor, 0.42)
        : Theme.lineSoft
    border.width: 1
    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
    Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

    MouseArea {
        id: cardArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (root.wf) root.activated(root.wf.id)
    }

    Column {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 8

        Row {
            spacing: 10
            width: parent.width

            CategoryIcon {
                kind: root.wf && root.wf.kinds && root.wf.kinds.length > 0 ? root.wf.kinds[0] : "wait"
                size: 32
                hovered: cardArea.containsMouse
                anchors.verticalCenter: parent.verticalCenter
            }

            Column {
                width: parent.width - 32 - 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Text {
                    text: root.wf ? root.wf.title : ""
                    color: Theme.text
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontBase
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                    width: parent.width
                }
                Text {
                    text: root.wf ? ("@" + root.wf.author) : ""
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: Theme.fontXs
                    elide: Text.ElideRight
                    width: parent.width
                }
            }
        }

        Text {
            text: root.wf ? root.wf.subtitle : ""
            color: Theme.text2
            font.family: Theme.familyBody
            font.pixelSize: Theme.fontXs
            lineHeight: 1.3
            wrapMode: Text.Wrap
            elide: Text.ElideRight
            maximumLineCount: 2
            width: parent.width
        }

        Item { width: 1; height: Math.max(0, parent.height - 14 - 32 - 8 - 30 - 8 - 18 - 14) }

        Row {
            spacing: 8
            width: parent.width

            Text {
                text: root.wf ? (root.wf.imports + " imports") : ""
                color: Theme.text2
                font.family: Theme.familyMono
                font.pixelSize: Theme.fontXs
                font.weight: Font.Medium
                anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
                width: 2; height: 2; radius: 1
                color: Theme.text3
                anchors.verticalCenter: parent.verticalCenter
                visible: root.wf && root.wf.steps !== undefined
            }
            Text {
                text: root.wf ? (root.wf.steps + " steps") : ""
                color: Theme.text3
                font.family: Theme.familyMono
                font.pixelSize: Theme.fontXs
                anchors.verticalCenter: parent.verticalCenter
            }
            Item { width: 1; height: 1; }  // spacer

            // Shell warning pip
            Rectangle {
                visible: root.wf && root.wf.hasShell
                width: 18; height: 18; radius: 9
                anchors.verticalCenter: parent.verticalCenter
                color: Qt.rgba(Theme.warn.r, Theme.warn.g, Theme.warn.b, 0.18)
                border.color: Qt.rgba(Theme.warn.r, Theme.warn.g, Theme.warn.b, 0.5)
                border.width: 1
                Text {
                    anchors.centerIn: parent
                    text: "›"
                    color: Theme.warn
                    font.family: Theme.familyBody
                    font.pixelSize: 12
                    font.weight: Font.Bold
                }
                ToolTip.visible: shellHover.containsMouse
                ToolTip.delay: 400
                ToolTip.text: "Contains shell commands — review before import"
                MouseArea { id: shellHover; anchors.fill: parent; hoverEnabled: true }
            }
        }
    }
}
