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
    // Implicit width is icon-chip + value-text + paddings; used when
    // the pill is sized to its content (e.g., explore page chips).
    // When parented with an explicit width: parent.width (canvas
    // cards), this is ignored.
    implicitWidth: (iconChip.visible ? iconChip.width + 8 : 0) + valueText.implicitWidth + 24
    radius: 8

    // Left-to-right gradient. Qt Quick's Gradient defaults to vertical;
    // setting `orientation` to Horizontal aligns with the mockup, where
    // pills shade from light to deep across their length.
    gradient: Gradient {
        orientation: Gradient.Horizontal
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

    // Leading icon sits on a small dark chip so it stays legible
    // against the gradient — without it, the glyph blends into the
    // colour at certain points along the stops. Glyph is always
    // white because the chip itself is opaque dark; gradTextColor
    // would render dark-on-dark for some kinds.
    Rectangle {
        id: iconChip
        visible: root.icon.length > 0
        anchors.left: parent.left
        anchors.leftMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        width: visible ? 22 : 0
        height: 22
        radius: 6
        color: Qt.rgba(0, 0, 0, 0.22)
        Text {
            anchors.centerIn: parent
            text: root.icon
            color: "#ffffff"
            font.family: Theme.familyBody
            font.pixelSize: Theme.catGlyphSize(root.kind)
            font.weight: Font.Bold
        }
    }

    // Value text fills the remaining width and elides on overflow.
    // Anchored layout (rather than a Row) so the right edge respects
    // the pill's width regardless of text length.
    Text {
        id: valueText
        anchors.left: iconChip.right
        anchors.leftMargin: iconChip.visible ? 8 : 8
        anchors.right: parent.right
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        text: root.text
        color: root.textColor
        font.family: Theme.familyBody
        font.pixelSize: 13
        font.weight: Font.DemiBold
        font.letterSpacing: -0.1
        elide: Text.ElideRight
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
