import QtQuick
import Wflow

// Action chip used inside step cards on the workflow canvas. Reads as a
// row with three slots: a category-tinted icon square on the left, a
// monospaced value in the middle, and an optional trailing icon (e.g.
// the "open import" arrow) on the right.
//
//   GradientPill {
//       kind: "shell"          // any Theme.catFor() key
//       text: "kitty -e nvim"
//       icon: "▷_"             // optional, leading
//       trailingIcon: "↗"      // optional, in a small chip on the right
//   }
//
// The legacy gradient skin shipped before the warm-coral palette landed.
// On the new tokens the gradients clashed with the flat surface ladder,
// so this is now a flat ink-tinted chip — same structural footprint as
// CategoryIcon scaled out to a row, sitting on Theme.surface with the
// kind's tint reserved for the icon square. The component name stays so
// existing callers continue to work without churn.
Rectangle {
    id: root

    property string kind: "key"
    property string text: ""
    // `icon` is now a presence sentinel — pass any non-empty string
    // to render the leading CategoryIcon, or "" to drop the slot.
    // The actual glyph comes from CategoryIcon's catGlyph(kind) so
    // overriding the character no longer has effect; existing
    // callers passing Theme.catGlyph(kind) still read correctly.
    property string icon: ""
    property string trailingIcon: ""
    property bool clickable: false

    signal clicked()

    implicitHeight: 36
    // Implicit width is icon-chip + value-text + paddings; used when
    // the pill is sized to its content. When parented with an explicit
    // width: parent.width (canvas cards), this is ignored.
    implicitWidth: (iconChip.visible ? iconChip.width + 8 : 0) + valueText.implicitWidth + 24
    radius: Theme.radiusMd
    color: Theme.surface
    border.color: Theme.lineSoft
    border.width: 1

    // Leading icon — delegates to the same CategoryIcon the step
    // palette uses, so glyph metrics (the chevron's tight optical
    // size, the timer's bigger one, etc.) stay identical between
    // toolbar and canvas. visible=false collapses the slot when the
    // caller passes no icon.
    CategoryIcon {
        id: iconChip
        visible: root.icon.length > 0
        anchors.left: parent.left
        anchors.leftMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        kind: root.kind
        size: 22
        width: visible ? size : 0
    }

    // Value text fills the remaining width and elides on overflow.
    // Mono font because the content is almost always a command, key
    // chord, or path — same register as wflows.com's .kdl-block
    // values, just inline.
    Text {
        id: valueText
        anchors.left: iconChip.right
        anchors.leftMargin: iconChip.visible ? 8 : 8
        anchors.right: trailingChip.visible ? trailingChip.left : parent.right
        anchors.rightMargin: trailingChip.visible ? 6 : 12
        anchors.verticalCenter: parent.verticalCenter
        text: root.text
        color: Theme.text
        font.family: Theme.familyMono
        font.pixelSize: Theme.fontSm
        font.weight: Font.Medium
        elide: Text.ElideRight
    }

    Rectangle {
        id: trailingChip
        visible: root.trailingIcon.length > 0
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        width: 22; height: 22
        radius: Theme.radiusSm
        color: Theme.surface2
        border.color: Theme.lineSoft
        border.width: 1
        Text {
            anchors.centerIn: parent
            text: root.trailingIcon
            color: Theme.text2
            font.family: Theme.familyBody
            font.pixelSize: Theme.fontXs
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.clickable
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.clicked()
    }
}
