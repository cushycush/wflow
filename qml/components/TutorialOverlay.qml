import QtQuick
import QtQuick.Controls
import Wflow

// 4500ms auto-dismiss so screen readers don't trap on it after the
// announcement. autoDismissMs: 0 keeps it sticky.
Rectangle {
    id: root

    property string text: ""
    property int autoDismissMs: 4500

    signal dismissed()

    width: Math.min(Math.max(160, contentRow.implicitWidth + 24), 360)
    height: contentRow.implicitHeight + 18
    radius: Theme.radiusMd
    color: Theme.surface3
    border.color: Theme.accent
    border.width: 1

    Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        radius: parent.radius - 1
        color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.06)
    }

    // Tooltip role so a screen reader announces and moves on.
    Accessible.role: Accessible.ToolTip
    Accessible.name: root.text

    Component.onCompleted: {
        if (root.autoDismissMs > 0) autoTimer.start()
    }

    Timer {
        id: autoTimer
        interval: root.autoDismissMs
        repeat: false
        onTriggered: root.dismissed()
    }

    Row {
        id: contentRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 12
        anchors.rightMargin: 8
        spacing: 8

        Text {
            text: root.text
            color: Theme.text
            font.family: Theme.familyBody
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
            width: parent.width - dismissBtn.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
        }

        // Always visible (not hover-gated) so keyboard users can Tab.
        Rectangle {
            id: dismissBtn
            width: 22; height: 22; radius: Theme.radiusSm
            color: dismissArea.containsMouse ? Theme.surface2 : "transparent"
            anchors.verticalCenter: parent.verticalCenter

            Text {
                anchors.centerIn: parent
                text: "×"
                color: Theme.text2
                font.family: Theme.familyBody
                font.pixelSize: 16
                font.weight: Font.DemiBold
            }

            MouseArea {
                id: dismissArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.dismissed()
            }
        }
    }
}
