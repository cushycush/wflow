import QtQuick
import QtQuick.Controls
import Wflow

// Centered empty state. Three kinds:
//   - "empty"    (default): existing concise copy for a returning user
//   - "first-run": welcome card with a hero glyph + secondary CTA, for
//                  brand-new installs the first time the library is empty
//   - "error"   : muted error copy
// The kind only affects the hero glyph above the title; layout is the
// same for all three. Title / description / actionLabel still drive
// the visible text. Use secondaryActionLabel to add a second button.
Item {
    id: root
    property string title: ""
    property string description: ""
    property string actionLabel: ""
    property string secondaryActionLabel: ""
    property string kind: "empty"   // "empty" | "first-run" | "error"
    signal actionClicked()
    signal secondaryActionClicked()

    Column {
        anchors.centerIn: parent
        spacing: 14
        width: Math.min(parent.width - 80, 480)

        // Hero glyph for the welcome variant. Subtle, single character,
        // not a decorative blob (per brand brief). 2px accent ring +
        // accent-colored "w" mark sized to feel like a wordmark.
        Rectangle {
            visible: root.kind === "first-run"
            width: 56; height: 56; radius: 28
            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.12)
            border.color: Theme.accent
            border.width: 2
            anchors.horizontalCenter: parent.horizontalCenter
            Text {
                anchors.centerIn: parent
                text: "w"
                color: Theme.accent
                font.family: Theme.familyBody
                font.pixelSize: 28
                font.weight: Font.DemiBold
            }
        }

        Text {
            text: root.title
            color: Theme.text
            font.family: Theme.familyBody
            font.pixelSize: Theme.fontLg
            font.weight: Font.DemiBold
            anchors.horizontalCenter: parent.horizontalCenter
            horizontalAlignment: Text.AlignHCenter
            width: parent.width
            wrapMode: Text.WordWrap
        }

        Text {
            text: root.description
            color: Theme.text3
            font.family: Theme.familyBody
            font.pixelSize: Theme.fontSm
            lineHeight: 1.5
            anchors.horizontalCenter: parent.horizontalCenter
            horizontalAlignment: Text.AlignHCenter
            width: parent.width
            wrapMode: Text.WordWrap
        }

        // Primary + optional secondary CTA, side by side. Spacing keeps
        // them visually grouped without collapsing into one button row.
        Row {
            visible: root.actionLabel.length > 0
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 10

            PrimaryButton {
                text: root.actionLabel
                topPadding: 10
                bottomPadding: 10
                leftPadding: 20
                rightPadding: 20
                onClicked: root.actionClicked()
            }
            SecondaryButton {
                visible: root.secondaryActionLabel.length > 0
                text: root.secondaryActionLabel
                topPadding: 10
                bottomPadding: 10
                leftPadding: 20
                rightPadding: 20
                onClicked: root.secondaryActionClicked()
            }
        }
    }
}
