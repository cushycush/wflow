import QtQuick
import Wflow

// Compressed step preview. Shows up inside Explore cards (so a user
// can see the SHAPE of a workflow at a glance before installing) and
// in the Canvas summary panel.
//
//   MiniStep {
//       kind: "shell"             // any Theme.gradFor() key
//       label: "Shell"            // small uppercase tag, optional
//       value: "kitty -e nvim"    // mono-typed body
//   }
//
// Stack a Column of these inside a `mini-stack` container; an
// optional left rail (handled by parent) renders the connector wire.
Rectangle {
    id: root

    property string kind: "shell"
    property string label: ""
    property string value: ""

    implicitHeight: 32
    radius: Theme.radiusMd
    color: Theme.surface
    border.color: Theme.lineSoft
    border.width: 1

    Row {
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 10
        spacing: 10

        // Mini step icon — delegates to CategoryIcon so the per-kind
        // glyph metrics (chevron tighter, timer larger, etc.) stay
        // identical to the toolbar palette and the canvas chips.
        CategoryIcon {
            id: iconBox
            anchors.verticalCenter: parent.verticalCenter
            kind: root.kind
            size: 18
        }

        Text {
            visible: root.label.length > 0
            text: root.label
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.text3
            font.family: Theme.familyBody
            font.pixelSize: 10
            font.weight: Font.Bold
            font.letterSpacing: 1.3
            font.capitalization: Font.AllUppercase
            // Reserve a fixed width so multiple stacked rows align.
            width: 56
        }

        Text {
            text: root.value
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.text2
            font.family: Theme.familyMono
            font.pixelSize: 12
            elide: Text.ElideRight
            width: parent.width
                - iconBox.width
                - (root.label.length > 0 ? 56 + 10 : 0)
                - 18
        }
    }
}
