import QtQuick
import QtQuick.Effects
import Wflow

// The signature gradient-filled affordance used inside cards across
// Explore + Canvas. Looks like a button but is presentation-only by
// default (set `clickable` to enable).
//
//   GradientPill {
//       kind: "shell"          // any Theme.gradFor() key
//       text: "kitty -e nvim"
//       icon: "▷_"             // optional, leading
//       trailingIcon: "↗"      // optional, in a small darker box on the right
//   }
Rectangle {
    id: root

    property string kind: "key"
    property string text: ""
    property string icon: ""
    property string trailingIcon: ""
    property bool clickable: false

    signal clicked()

    readonly property var grad: Theme.gradFor(kind)
    readonly property color textColor: Theme.gradTextColor(kind)

    implicitHeight: 36
    implicitWidth: row.implicitWidth + 24
    radius: 8

    // Vertical gradient — Qt Quick's Rectangle.gradient is top-to-
    // bottom only. We tilt the start stop a touch toward the lighter
    // end so the pill reads with a subtle highlight at the top.
    gradient: Gradient {
        GradientStop { position: 0.0; color: root.grad[0] }
        GradientStop { position: 1.0; color: root.grad[1] }
    }

    // Inner highlight + soft outer glow shaped to the pill.
    layer.enabled: true
    layer.effect: MultiEffect {
        shadowEnabled: true
        shadowColor: Qt.rgba(0, 0, 0, 0.35)
        shadowBlur: 0.6
        shadowVerticalOffset: 4
    }

    Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Qt.rgba(1, 1, 1, 0.18)
        radius: parent.radius
    }

    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: 12
        spacing: 10

        Text {
            visible: root.icon.length > 0
            text: root.icon
            color: root.textColor
            font.family: Theme.familyBody
            font.pixelSize: 12
            anchors.verticalCenter: parent.verticalCenter
            opacity: 0.9
        }
        Text {
            text: root.text
            color: root.textColor
            font.family: Theme.familyBody
            font.pixelSize: 12.5
            font.weight: Font.DemiBold
            font.letterSpacing: -0.1
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    Rectangle {
        visible: root.trailingIcon.length > 0
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        width: 22; height: 22
        radius: 5
        color: Qt.rgba(1, 1, 1, 0.15)
        Text {
            anchors.centerIn: parent
            text: root.trailingIcon
            color: root.textColor
            font.family: Theme.familyBody
            font.pixelSize: 11
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.clickable
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.clicked()
    }
}
