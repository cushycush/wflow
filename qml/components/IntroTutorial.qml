import QtQuick
import QtQuick.Controls
import Wflow

// First-run multi-step welcome tour. Shows once when state.toml is
// fresh (`stateCtrl.is_first_run`) and the user hasn't already
// dismissed the same tutorial. Each "page" is a single card with
// text + an illustration line; navigation via Next / Skip / Back.
//
// State key: stateCtrl tutorial "intro_tour". Marked seen on Finish
// or Skip, persisted across launches.
Dialog {
    id: root
    parent: Overlay.overlay
    modal: true
    closePolicy: Popup.NoAutoClose

    property var stateCtrl: null
    property int step: 0
    readonly property int totalSteps: 4

    width: 540
    height: 380
    anchors.centerIn: parent

    background: Rectangle {
        color: Theme.surface
        radius: Theme.radiusMd
        border.color: Theme.line
        border.width: 1
    }

    function start() {
        step = 0
        open()
    }

    function _finish() {
        if (stateCtrl) stateCtrl.mark_tutorial_seen("intro_tour")
        close()
    }

    contentItem: Item {
        anchors.fill: parent

        Column {
            anchors.fill: parent
            anchors.margins: 28
            spacing: 16

            // Step indicator pills + skip
            Row {
                width: parent.width
                spacing: 6

                Repeater {
                    model: root.totalSteps
                    delegate: Rectangle {
                        width: model.index === root.step ? 22 : 6
                        height: 6
                        radius: 3
                        color: model.index === root.step
                            ? Theme.accent
                            : (model.index < root.step
                                ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55)
                                : Theme.surface3)
                        anchors.verticalCenter: parent.verticalCenter
                        Behavior on width { NumberAnimation { duration: Theme.dur(Theme.durFast) } }
                    }
                }

                Item { width: parent.width - 4 * 8 - 22 - 6 * 3 - 60; height: 1 }

                Rectangle {
                    width: skipText.implicitWidth + 16
                    height: 22
                    radius: Theme.radiusSm
                    color: skipArea.containsMouse ? Theme.surface2 : "transparent"
                    anchors.verticalCenter: parent.verticalCenter
                    Behavior on color { ColorAnimation { duration: Theme.durFast } }
                    Text {
                        id: skipText
                        anchors.centerIn: parent
                        text: "Skip"
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontXs
                        font.weight: Font.Medium
                    }
                    MouseArea {
                        id: skipArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._finish()
                    }
                }
            }

            // The current step's body. Header + paragraph + a small
            // accent illustration. Each step is a self-contained
            // Item visible iff its index matches root.step.
            Item {
                width: parent.width
                height: parent.height - 6 - 16 - 36 - 16

                // Step 0: welcome
                Column {
                    anchors.fill: parent
                    visible: root.step === 0
                    spacing: 14

                    Text {
                        text: "Welcome to wflow."
                        color: Theme.text
                        font.family: Theme.familyBody
                        font.pixelSize: 28
                        font.weight: Font.Bold
                    }
                    Text {
                        text: "Shortcuts for Linux. wflow runs sequences of keystrokes, clicks, shell commands, and waits — visually authored, plain-text on disk."
                        color: Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontMd
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }
                    Text {
                        text: "A quick tour: 30 seconds, four screens. Skip any time."
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.italic: true
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }
                }

                // Step 1: Library
                Column {
                    anchors.fill: parent
                    visible: root.step === 1
                    spacing: 14

                    Text {
                        text: "1 / The library"
                        color: Theme.accent
                        font.family: Theme.familyMono
                        font.pixelSize: Theme.fontXs
                        font.weight: Font.Bold
                        font.letterSpacing: 1.0
                    }
                    Text {
                        text: "Your saved workflows live in the library."
                        color: Theme.text
                        font.family: Theme.familyBody
                        font.pixelSize: 22
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: "Click any card to open it in the editor. Right-click for Duplicate / Delete. Drag a card onto a folder tile to move it. Use the sidebar tree to nest folders — type 'a/b' in '+ New folder' to create both."
                        color: Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }
                }

                // Step 2: Editor
                Column {
                    anchors.fill: parent
                    visible: root.step === 2
                    spacing: 14

                    Text {
                        text: "2 / The editor"
                        color: Theme.accent
                        font.family: Theme.familyMono
                        font.pixelSize: Theme.fontXs
                        font.weight: Font.Bold
                        font.letterSpacing: 1.0
                    }
                    Text {
                        text: "Drag a step from the palette onto the canvas."
                        color: Theme.text
                        font.family: Theme.familyBody
                        font.pixelSize: 22
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: "The dock on the left is your toolbox: Type, Click, Shell, When, Repeat, Use, and so on. Drop one onto the canvas to add it. Click any step to edit its details on the right. Containers (when / unless / repeat) have an 'Open →' button — click to descend into the inner sequence; use the breadcrumb to climb back."
                        color: Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }
                }

                // Step 3: Run + Record
                Column {
                    anchors.fill: parent
                    visible: root.step === 3
                    spacing: 14

                    Text {
                        text: "3 / Run + Record"
                        color: Theme.accent
                        font.family: Theme.familyMono
                        font.pixelSize: Theme.fontXs
                        font.weight: Font.Bold
                        font.letterSpacing: 1.0
                    }
                    Text {
                        text: "Click ▶ Run to play the workflow. Or record one."
                        color: Theme.text
                        font.family: Theme.familyBody
                        font.pixelSize: 22
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: "Run plays each step in order, with a status indicator on the card as it goes. Record (the red tab in the nav) captures keystrokes, clicks, and window focus changes from your real input — useful for transcribing a manual sequence into a saved workflow. Workflows live as plain .kdl files under ~/.config/wflow/workflows."
                        color: Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }
                }
            }

            // Nav row — Back / Next / Finish
            Row {
                width: parent.width
                spacing: 8

                Rectangle {
                    width: backText.implicitWidth + 28
                    height: 36
                    radius: Theme.radiusSm
                    color: backArea.containsMouse ? Theme.surface2 : "transparent"
                    border.color: Theme.lineSoft
                    border.width: 1
                    visible: root.step > 0
                    Behavior on color { ColorAnimation { duration: Theme.durFast } }
                    Text {
                        id: backText
                        anchors.centerIn: parent
                        text: "Back"
                        color: Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.Medium
                    }
                    MouseArea {
                        id: backArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.step = Math.max(0, root.step - 1)
                    }
                }

                Item {
                    width: parent.width - (root.step > 0 ? backText.implicitWidth + 28 + 8 : 0)
                          - nextText.implicitWidth - 32 - 8
                    height: 1
                }

                Rectangle {
                    width: nextText.implicitWidth + 32
                    height: 36
                    radius: Theme.radiusSm
                    color: nextArea.containsMouse ? Theme.accentHi : Theme.accent
                    Behavior on color { ColorAnimation { duration: Theme.durFast } }
                    Text {
                        id: nextText
                        anchors.centerIn: parent
                        text: root.step === root.totalSteps - 1 ? "Get started" : "Next →"
                        color: Theme.accentText
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.DemiBold
                    }
                    MouseArea {
                        id: nextArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.step >= root.totalSteps - 1) {
                                root._finish()
                            } else {
                                root.step += 1
                            }
                        }
                    }
                }
            }
        }
    }
}
