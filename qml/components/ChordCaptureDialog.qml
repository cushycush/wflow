import QtQuick
import QtQuick.Controls
import Wflow

// Captures a chord like "ctrl+shift+t". actions::normalize_chord
// canonicalises further on save.
Dialog {
    id: root
    modal: true
    closePolicy: Popup.CloseOnEscape
    width: 460
    // Centre on the window overlay rather than whatever Item the
    // dialog is declared inside. Without this, instantiating inside
    // a small pinned card (like the editor's trigger pin) makes the
    // dialog centre on the card and spill off-screen.
    parent: Overlay.overlay
    anchors.centerIn: parent

    property string initialChord: ""
    // whenKind: "" | "window-class" | "window-title"; both empty → no scope.
    property string initialWhenKind: ""
    property string initialWhenValue: ""

    property string capturedChord: ""
    property string capturedWhenKind: ""
    property string capturedWhenValue: ""

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
                : "Press the chord, hold modifiers (Ctrl/Shift/Alt/Super) and tap a key. Or type the chord directly below if your compositor's already bound it (it'll fire the existing binding instead of letting wflow capture). Esc to cancel."
            color: Theme.text2
            font.family: Theme.familyBody
            font.pixelSize: Theme.fontSm
            wrapMode: Text.WordWrap
            width: parent.width
            lineHeight: 1.4
        }

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
                    // Standalone modifiers don't commit; wait for a key.
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

        // Wayland apps can't pre-empt the compositor's bindings; if a
        // chord is already bound (launcher, workspace switcher), this
        // dialog never sees the keypress. Typing it manually is the
        // workaround. Also covers Print / XF86 keys.
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
                        // Bridge canonicalises on save, so "Cmd+Shift+T"
                        // typed here lands as "super+shift+t".
                        root.capturedChord = trimmed
                    } else if (root.capturedChord === text) {
                        root.capturedChord = ""
                    }
                }
                Keys.onReturnPressed: if (saveBtn.enabled) saveBtn.clicked()
            }
        }

        // Mirrors KDL's `when window-class "firefox"`; empty = always.
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
                    width: 200
                    height: 36
                    model: [
                        { label: "Always (no condition)", value: "" },
                        { label: "Window class is", value: "window-class" },
                        { label: "Window title contains", value: "window-title" }
                    ]
                    textRole: "label"
                    valueRole: "value"
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm

                    // Default ControlsImpl style fights the brand;
                    // replace with our surface-pill shape.
                    background: Rectangle {
                        radius: Theme.radiusSm
                        color: whenKindCombo.hovered
                            ? Theme.surface2
                            : Qt.rgba(Theme.surface2.r, Theme.surface2.g, Theme.surface2.b, 0.5)
                        border.color: whenKindCombo.activeFocus
                            ? Theme.accent
                            : (whenKindCombo.hovered ? Theme.line : Theme.lineSoft)
                        border.width: 1
                        Behavior on border.color {
                            ColorAnimation { duration: Theme.dur(Theme.durFast) }
                        }
                    }

                    contentItem: Text {
                        anchors.left: parent.left
                        anchors.right: caretIcon.left
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 12
                        anchors.rightMargin: 6
                        text: whenKindCombo.displayText
                        color: Theme.text
                        font: whenKindCombo.font
                        elide: Text.ElideRight
                        verticalAlignment: Text.AlignVCenter
                    }

                    indicator: Item {
                        id: caretIcon
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: 8
                        height: 5
                        Rectangle {
                            x: 0; y: 0
                            width: 5; height: 1.4
                            radius: 0.7
                            color: Theme.text2
                            transform: Rotation { origin.x: 0; origin.y: 0.7; angle: 30 }
                        }
                        Rectangle {
                            x: 4; y: 0
                            width: 5; height: 1.4
                            radius: 0.7
                            color: Theme.text2
                            transform: Rotation { origin.x: 5; origin.y: 0.7; angle: -30 }
                        }
                    }

                    popup: Popup {
                        y: whenKindCombo.height + 4
                        width: whenKindCombo.width
                        implicitHeight: contentItem.implicitHeight + 8
                        padding: 4

                        background: Rectangle {
                            color: Theme.surface
                            radius: Theme.radiusSm
                            border.color: Theme.line
                            border.width: 1
                        }

                        contentItem: ListView {
                            clip: true
                            implicitHeight: contentHeight
                            model: whenKindCombo.popup.visible
                                ? whenKindCombo.delegateModel
                                : null
                            currentIndex: whenKindCombo.highlightedIndex
                        }
                    }

                    delegate: ItemDelegate {
                        width: whenKindCombo.width
                        height: 32

                        background: Rectangle {
                            color: whenKindCombo.highlightedIndex === index
                                ? Theme.surface2
                                : (hovered ? Theme.surface2 : "transparent")
                            radius: Theme.radiusXs
                            Behavior on color {
                                ColorAnimation { duration: Theme.dur(Theme.durFast) }
                            }
                        }

                        contentItem: Text {
                            text: modelData.label
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            font.weight: whenKindCombo.currentIndex === index
                                ? Font.DemiBold
                                : Font.Normal
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Component.onCompleted: {
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
                            // Drop leftover value so it doesn't round-trip.
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
                    : "Substring of the focused window's title bar text. Useful for in-app context, \"Inbox\" only when Gmail is open."
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

    function _isModifierKey(key) {
        return key === Qt.Key_Control
            || key === Qt.Key_Shift
            || key === Qt.Key_Alt
            || key === Qt.Key_Meta
            || key === Qt.Key_AltGr
            || key === Qt.Key_CapsLock
    }

    // Named keys (Return / Escape / F1…) have empty event.text and
    // need the explicit table; letters/digits come through .text.
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
        return key.toString()
    }
}
