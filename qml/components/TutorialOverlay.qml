import QtQuick
import QtQuick.Controls
import Wflow

// One-shot tutorial tooltip — a styled callout box the caller anchors
// to whatever element they want to teach about. Caller owns the
// "have we shown this before" state and the visibility binding.
//
// Usage (inside a parent that holds the target as a sibling):
//
//   TutorialOverlay {
//       text: "Start by adding a step — try Type text or Press key."
//       anchors.bottom: addStepRow.top
//       anchors.bottomMargin: 4
//       anchors.horizontalCenter: addStepRow.horizontalCenter
//       visible: !stateCtrl.tutorial_seen("blank_workflow")
//       onDismissed: stateCtrl.mark_tutorial_seen("blank_workflow")
//   }
//
// a11y: 4500ms auto-dismiss timer so screen-reader users don't get
// stuck on the focus-trapping tooltip after it announces. Caller can
// disable via autoDismissMs: 0 if a use case needs it sticky.
Rectangle {
    id: root

    /// One-line text shown in the bubble. Caller's responsibility —
    /// keep it short, the bubble caps width at 360.
    property string text: ""

    /// Auto-dismiss after this many ms. Set 0 to disable.
    property int autoDismissMs: 4500

    signal dismissed()

    width: Math.min(Math.max(160, contentRow.implicitWidth + 24), 360)
    height: contentRow.implicitHeight + 18
    radius: Theme.radiusMd
    color: Theme.surface3
    border.color: Theme.accent
    border.width: 1

    // Subtle accent-tinted background so it reads as "wflow is talking
    // to you" rather than another part of the editor chrome.
    Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        radius: parent.radius - 1
        color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.06)
    }

    // ARIA-equivalent — Qt Quick's Accessibility attached object
    // forwards to AT-SPI. Tooltip role so a screen reader announces
    // and moves on rather than trapping focus.
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

        // × dismiss. Always visible (not hover-gated) so keyboard
        // users can tab to it without first knowing it exists.
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
