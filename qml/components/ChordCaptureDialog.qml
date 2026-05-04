import QtQuick
import QtQuick.Controls
import Wflow

// Modal that listens for a single keypress + modifier mask and emits
// a canonical chord string. Used by the Triggers tab and the per-
// workflow trigger panel to bind a hotkey without hand-editing KDL.
//
// Format produced: "ctrl+shift+t", "super+1", "Return", "alt+space"
// — the same shape the KDL `trigger { chord "..." }` block accepts
// and `actions::normalize_chord` canonicalises further.
//
// Usage:
//   ChordCaptureDialog {
//       id: chordDialog
//       onCaptured: (chord) => libCtrl.set_chord(targetId, chord)
//   }
//   ...
//   chordDialog.open()
Dialog {
    id: root
    modal: true
    closePolicy: Popup.CloseOnEscape
    width: 460
    anchors.centerIn: parent

    /// Optional initial chord — when set, the dialog opens with the
    /// existing binding pre-displayed (so the user sees what they're
    /// replacing). Press a new combo to override.
    property string initialChord: ""

    /// Captured chord string. Updates live as the user presses keys;
    /// confirmCaptured signal fires on Save.
    property string capturedChord: ""

    signal captured(string chord)
    signal cleared()

    onOpened: {
        capturedChord = initialChord
        captureFocus.forceActiveFocus()
    }

    header: Item { width: 0; height: 0 }
    footer: Item { width: 0; height: 0 }

    background: Rectangle {
        color: Theme.surface
        radius: Theme.radiusMd
        border.color: Theme.line
        border.width: 1
    }

    padding: 24
    contentItem: Column {
        spacing: 18

        Text {
            text: "Bind a chord"
            color: Theme.text
            font.family: Theme.familyBody
            font.pixelSize: Theme.fontXl
            font.weight: Font.DemiBold
        }

        Text {
            text: root.initialChord.length > 0
                ? "Currently bound to " + root.initialChord + ". Press a new combination to replace, or click Clear to unbind."
                : "Press the chord you want to bind. Hold modifiers (Ctrl, Shift, Alt, Super) and tap a key. Esc to cancel."
            color: Theme.text2
            font.family: Theme.familyBody
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
            width: parent.width
            lineHeight: 1.4
        }

        // The capture surface — a tall pill that displays the live
        // chord. KeyHandler activates when this Item has focus,
        // which happens on Dialog.opened.
        Rectangle {
            id: captureSurface
            width: parent.width
            height: 64
            radius: Theme.radiusSm
            color: captureFocus.activeFocus
                ? Theme.surface2
                : Qt.rgba(Theme.surface2.r, Theme.surface2.g, Theme.surface2.b, 0.5)
            border.color: captureFocus.activeFocus ? Theme.accent : Theme.lineSoft
            border.width: 1
            Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

            Text {
                anchors.centerIn: parent
                text: root.capturedChord.length > 0
                    ? root.capturedChord
                    : "Press a chord…"
                color: root.capturedChord.length > 0 ? Theme.text : Theme.text3
                font.family: Theme.familyMono
                font.pixelSize: Theme.fontLg
                font.weight: Font.DemiBold
                font.letterSpacing: 0.4
            }

            Item {
                id: captureFocus
                anchors.fill: parent
                focus: true
                Keys.onPressed: (event) => {
                    // Ignore standalone modifier presses — wait for a
                    // non-modifier key to commit a chord.
                    if (_isModifierKey(event.key)) {
                        event.accepted = true
                        return
                    }
                    if (event.key === Qt.Key_Escape) {
                        root.reject()
                        return
                    }
                    const parts = []
                    if (event.modifiers & Qt.ControlModifier) parts.push("ctrl")
                    if (event.modifiers & Qt.AltModifier) parts.push("alt")
                    if (event.modifiers & Qt.ShiftModifier) parts.push("shift")
                    if (event.modifiers & Qt.MetaModifier) parts.push("super")
                    parts.push(_keyName(event.key, event.text))
                    root.capturedChord = parts.join("+")
                    event.accepted = true
                }
            }
        }

        Row {
            width: parent.width
            spacing: 8
            layoutDirection: Qt.RightToLeft

            Button {
                id: saveBtn
                text: "Bind"
                enabled: root.capturedChord.length > 0
                topPadding: 8
                bottomPadding: 8
                leftPadding: 18
                rightPadding: 18

                background: Rectangle {
                    radius: Theme.radiusSm
                    color: !saveBtn.enabled
                        ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.4)
                        : (saveBtn.hovered ? Theme.accentHi : Theme.accent)
                    Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                }
                contentItem: Text {
                    text: saveBtn.text
                    color: Theme.accentText
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                onClicked: {
                    root.captured(root.capturedChord)
                    root.accept()
                }
            }

            SecondaryButton {
                text: "Cancel"
                onClicked: root.reject()
            }

            Item { width: parent.width - saveBtn.width - 10; height: 1 }

            // Clear is on the left, only when there's an existing
            // chord to remove. Cancel/Bind handle the no-binding case.
            SecondaryButton {
                visible: root.initialChord.length > 0
                text: "Clear binding"
                onClicked: {
                    root.cleared()
                    root.accept()
                }
            }
        }
    }

    // Modifier-only keys we ignore at the press level. The chord
    // commits when the user presses an actual letter / number /
    // function key with the modifiers held.
    function _isModifierKey(key) {
        return key === Qt.Key_Control
            || key === Qt.Key_Shift
            || key === Qt.Key_Alt
            || key === Qt.Key_Meta
            || key === Qt.Key_AltGr
            || key === Qt.Key_CapsLock
    }

    // Map a Qt key code to the chord-string token. Letters/digits
    // come out lowercase via event.text (cheap path); named keys
    // (Return, Escape, F1…) need the explicit table because event.text
    // is empty for them.
    function _keyName(key, text) {
        const named = ({})
        named[Qt.Key_Return]    = "Return"
        named[Qt.Key_Enter]     = "Return"
        named[Qt.Key_Escape]    = "Escape"
        named[Qt.Key_Tab]       = "Tab"
        named[Qt.Key_Backspace] = "BackSpace"
        named[Qt.Key_Delete]    = "Delete"
        named[Qt.Key_Insert]    = "Insert"
        named[Qt.Key_Home]      = "Home"
        named[Qt.Key_End]       = "End"
        named[Qt.Key_PageUp]    = "Page_Up"
        named[Qt.Key_PageDown]  = "Page_Down"
        named[Qt.Key_Up]        = "Up"
        named[Qt.Key_Down]      = "Down"
        named[Qt.Key_Left]      = "Left"
        named[Qt.Key_Right]     = "Right"
        named[Qt.Key_Space]     = "space"
        for (let i = 1; i <= 24; ++i) {
            named[Qt["Key_F" + i]] = "F" + i
        }
        if (named[key]) return named[key]
        if (text && text.length > 0) {
            return text.toLowerCase()
        }
        // Fallback — Qt's key constant name without the prefix.
        return key.toString()
    }
}
