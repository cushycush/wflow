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
    /// Initial values for the when-predicate, mirrored from the
    /// existing trigger so editing an existing binding keeps its
    /// scope. `whenKind` is "" / "window-class" / "window-title";
    /// `whenValue` is the matched string. Both empty → no predicate.
    property string initialWhenKind: ""
    property string initialWhenValue: ""

    /// Captured chord string. Updates live as the user presses keys;
    /// confirmCaptured signal fires on Save.
    property string capturedChord: ""
    /// Predicate state. Updated by the When section's UI.
    property string capturedWhenKind: ""
    property string capturedWhenValue: ""

    /// Emitted on Bind. The handler is expected to call
    /// libCtrl.set_chord(id, chord, whenKind, whenValue). When the
    /// user didn't pick a predicate both whenKind and whenValue are
    /// empty strings.
    signal captured(string chord, string whenKind, string whenValue)
    signal cleared()

    onOpened: {
        capturedChord = initialChord
        capturedWhenKind = initialWhenKind
        capturedWhenValue = initialWhenValue
        manualField.text = initialChord
        whenValueField.text = initialWhenValue
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
                ? "Currently bound to " + root.initialChord + ". Press a new combination to replace, type one in, or Clear to unbind."
                : "Press the chord — hold modifiers (Ctrl/Shift/Alt/Super) and tap a key. Or type the chord directly below if your compositor's already bound it (it'll fire the existing binding instead of letting wflow capture). Esc to cancel."
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
                    manualField.text = root.capturedChord
                    event.accepted = true
                }
            }
        }

        // Manual fallback. Wayland apps can't grab keys ahead of the
        // compositor; if a chord is already bound to a launcher /
        // workspace switcher / etc, pressing it fires that bind and
        // wflow never sees the keypress. Typing the chord here is
        // the workaround. Also useful for chords that don't have a
        // unique key event we can capture (Print, XF86 keys, etc).
        Column {
            width: parent.width
            spacing: 4
            Row {
                spacing: 8
                Text {
                    text: "OR TYPE A CHORD"
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 9
                    font.weight: Font.Bold
                    font.letterSpacing: 0.8
                }
                Text {
                    text: "ctrl+shift+t · super+space · F11 · alt+Return"
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 9
                    font.letterSpacing: 0.4
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            TextField {
                id: manualField
                width: parent.width
                placeholderText: "ctrl+shift+t"
                font.family: Theme.familyMono
                font.pixelSize: Theme.fontSm
                color: Theme.text
                placeholderTextColor: Theme.text3
                background: Rectangle {
                    radius: Theme.radiusSm
                    color: manualField.activeFocus
                        ? Theme.surface2
                        : Qt.rgba(Theme.surface2.r, Theme.surface2.g, Theme.surface2.b, 0.5)
                    border.color: manualField.activeFocus ? Theme.accent : Theme.lineSoft
                    border.width: 1
                    Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                }
                onTextChanged: {
                    const trimmed = text.trim()
                    if (trimmed.length > 0) {
                        // Mirror the manual entry into the captured
                        // chord so the Bind button enables and the
                        // capture-pill above shows what's about to
                        // be saved. Normalisation (canonical form)
                        // happens server-side on save via the bridge,
                        // so the user can type "Cmd+Shift+T" and the
                        // resulting bind is "super+shift+t" without
                        // them having to know the canonical spelling.
                        root.capturedChord = trimmed
                    } else if (root.capturedChord === text) {
                        root.capturedChord = ""
                    }
                }
                Keys.onReturnPressed: if (saveBtn.enabled) saveBtn.clicked()
            }
        }

        // When-predicate scope. Lets the user constrain the chord
        // to fire only when a specific window is focused — same
        // shape as KDL's `when window-class "firefox"`. Optional;
        // empty kind = fire unconditionally.
        Column {
            width: parent.width
            spacing: 6

            Text {
                text: "FIRE ONLY WHEN…"
                color: Theme.text3
                font.family: Theme.familyMono
                font.pixelSize: 9
                font.weight: Font.Bold
                font.letterSpacing: 0.8
            }

            Row {
                spacing: 8
                width: parent.width

                ComboBox {
                    id: whenKindCombo
                    width: 180
                    model: [
                        { label: "Always (no condition)", value: "" },
                        { label: "Window class is", value: "window-class" },
                        { label: "Window title contains", value: "window-title" }
                    ]
                    textRole: "label"
                    valueRole: "value"
                    Component.onCompleted: {
                        // Pre-select the existing kind if we're
                        // editing a binding that already has one.
                        for (let i = 0; i < model.length; ++i) {
                            if (model[i].value === root.capturedWhenKind) {
                                currentIndex = i
                                return
                            }
                        }
                        currentIndex = 0
                    }
                    onActivated: {
                        root.capturedWhenKind = currentValue
                        if (currentValue === "") {
                            // Clear the value when the user picks
                            // "Always" so a leftover string doesn't
                            // round-trip into the saved KDL.
                            whenValueField.text = ""
                            root.capturedWhenValue = ""
                        }
                    }
                }

                TextField {
                    id: whenValueField
                    visible: root.capturedWhenKind.length > 0
                    width: parent.width - whenKindCombo.width - 8
                    placeholderText: root.capturedWhenKind === "window-class"
                        ? "firefox · slack · code (case-insensitive)"
                        : "Inbox · Pull Request · Discord (substring)"
                    font.family: Theme.familyMono
                    font.pixelSize: Theme.fontSm
                    color: Theme.text
                    placeholderTextColor: Theme.text3
                    background: Rectangle {
                        radius: Theme.radiusSm
                        color: whenValueField.activeFocus
                            ? Theme.surface2
                            : Qt.rgba(Theme.surface2.r, Theme.surface2.g, Theme.surface2.b, 0.5)
                        border.color: whenValueField.activeFocus ? Theme.accent : Theme.lineSoft
                        border.width: 1
                        Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    }
                    onTextChanged: root.capturedWhenValue = text.trim()
                }
            }

            Text {
                visible: root.capturedWhenKind.length > 0
                text: root.capturedWhenKind === "window-class"
                    ? "Wayland app_id (Hyprland: hyprctl activewindow → class). Case-insensitive substring match."
                    : "Substring of the focused window's title bar text. Useful for in-app context — \"Inbox\" only when Gmail is open."
                color: Theme.text3
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontXs
                wrapMode: Text.WordWrap
                width: parent.width
                lineHeight: 1.3
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
                    root.captured(
                        root.capturedChord,
                        root.capturedWhenKind,
                        root.capturedWhenValue
                    )
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
