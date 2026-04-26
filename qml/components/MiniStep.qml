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
    property string icon: Theme.catGlyph(kind)

    implicitHeight: 32
    radius: 9
    color: Theme.surface
    border.color: Theme.lineSoft
    border.width: 1

    readonly property var grad: Theme.gradFor(kind)
    readonly property color iconText: Theme.gradTextColor(kind)

    Row {
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 10
        spacing: 10

        // Mini gradient icon — a smaller cousin of GradientPill, here
        // sitting flush left on the row.
        Rectangle {
            id: iconBox
            anchors.verticalCenter: parent.verticalCenter
            width: 18
            height: 18
            radius: 5
            gradient: Gradient {
                GradientStop { position: 0; color: root.grad[0] }
                GradientStop { position: 1; color: root.grad[1] }
            }
            Rectangle {
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - 4
                height: 1
                color: Qt.rgba(1, 1, 1, 0.18)
            }
            Text {
                anchors.centerIn: parent
                text: root.icon
                color: root.iconText
                font.family: Theme.familyBody
                font.pixelSize: 10
                font.weight: Font.Bold
            }
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
            font.pixelSize: 11.5
            elide: Text.ElideRight
            width: parent.width
                - iconBox.width
                - (root.label.length > 0 ? 56 + 10 : 0)
                - 18
        }
    }
}
