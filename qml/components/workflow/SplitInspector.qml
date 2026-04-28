import QtQuick
import QtQuick.Controls
import Wflow

// Variant 2 — SPLIT
// List of steps on the left, full inspector on the right for the selected step.
// Two-pane, detail-oriented. Great for editing a single action closely.
Item {
    id: root
    property var actions: []
    property int activeStepIndex: -1
    property bool running: false
    property int selectedIndex: 0
    // { [stepIndex]: "ok"|"skipped"|"error" } from the engine's step_done signal.
    property var stepStatuses: ({})

    signal valueEdited(int stepIndex, string newPrimary)
    // Emitted when an option editor commits a change. `path` is one of
    // "enabled", "on_error", or "action.<field>" (delay_ms, clear_modifiers,
    // retries, backoff_ms, timeout_ms). Empty-string / null values signal
    // "reset to default".
    signal optionEdited(int stepIndex, string path, var value)
    // Emitted when the user picks a kind from the add-step picker; parent
    // decides the default action body.
    signal addStepRequested(string kind)
    signal deleteStepRequested(int stepIndex)
    signal moveStepRequested(int from, int to)

    // True when the parent wants to show the first-time tutorial
    // tooltip anchored to the + Add step footer. The parent owns the
    // "have we shown this before" state; the inspector just renders.
    property bool showTutorial: false
    signal tutorialDismissed()

    // Kinds exposed in the add-step picker. Flow-control (repeat, conditional,
    // use) is intentionally excluded — those need a richer editor and live
    // in `wflow edit` for now.
    readonly property var _pickableKinds: [
        { kind: "key",       label: "Key chord" },
        { kind: "type",      label: "Type text" },
        { kind: "click",     label: "Click" },
        { kind: "move",      label: "Move cursor" },
        { kind: "scroll",    label: "Scroll" },
        { kind: "focus",     label: "Focus window" },
        { kind: "wait",      label: "Wait" },
        { kind: "shell",     label: "Shell command" },
        { kind: "notify",    label: "Notification" },
        { kind: "clipboard", label: "Clipboard" },
        { kind: "note",      label: "Note" }
    ]

    implicitHeight: 520

    Row {
        anchors.fill: parent
        spacing: 16

        // Left — thin step list
        Rectangle {
            width: 320
            height: parent.height
            radius: Theme.radiusMd
            color: Theme.surface
            border.color: Theme.lineSoft
            border.width: 1

            // ScrollView so a workflow longer than the panel doesn't
            // clip past the bottom. Default scroll bar is fine; the
            // user can wheel or click+drag to reach later steps.
            ScrollView {
                anchors.fill: parent
                anchors.topMargin: 12
                anchors.bottomMargin: 12
                clip: true
                contentWidth: availableWidth

                Column {
                    width: parent.width
                    spacing: 2

                Repeater {
                    model: root.actions
                    delegate: Rectangle {
                        id: stepRow
                        readonly property bool isSelected: model.index === root.selectedIndex
                        readonly property bool isActive: model.index === root.activeStepIndex
                        readonly property string status: {
                            const s = root.stepStatuses
                            if (!s) return ""
                            const v = s[model.index]
                            return v === undefined ? "" : v
                        }
                        readonly property color catColor: Theme.catFor(modelData.kind)

                        width: parent.width
                        height: 48
                        color: {
                            if (isSelected) return Qt.rgba(catColor.r, catColor.g, catColor.b, 0.15)
                            if (rowArea.containsMouse) return Theme.surface2
                            return "transparent"
                        }
                        Behavior on color { ColorAnimation { duration: Theme.durFast } }

                        MouseArea {
                            id: rowArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.selectedIndex = model.index
                        }

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 12
                            spacing: 12

                            Item {
                                width: 20
                                height: parent.height
                                anchors.verticalCenter: parent.verticalCenter

                                Text {
                                    anchors.centerIn: parent
                                    visible: stepRow.status === ""
                                    text: String(model.index + 1).padStart(2, "0")
                                    color: stepRow.isActive ? stepRow.catColor : Theme.text3
                                    font.family: Theme.familyMono
                                    font.pixelSize: 11
                                }
                                // Status glyph replaces the step number once the
                                // engine reports an outcome for this step.
                                Text {
                                    anchors.centerIn: parent
                                    visible: stepRow.status !== ""
                                    text: stepRow.status === "ok"      ? "✓"
                                        : stepRow.status === "error"   ? "✗"
                                        : stepRow.status === "skipped" ? "·"
                                        : ""
                                    color: stepRow.status === "ok"      ? Theme.ok
                                         : stepRow.status === "error"   ? Theme.err
                                         : Theme.text3
                                    font.family: Theme.familyBody
                                    font.pixelSize: 14
                                    font.weight: Font.Bold
                                }
                            }
                            CategoryIcon {
                                kind: modelData.kind
                                size: 26
                                hovered: rowArea.containsMouse
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                // Reserve 78px on the right for the hover controls
                                // so layout doesn't shift on mouseover.
                                width: parent.width - 20 - 12 - 26 - 12 - 78
                                spacing: 1
                                Text {
                                    text: modelData.summary
                                    color: Theme.text
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontSm
                                    font.weight: stepRow.isSelected ? Font.DemiBold : Font.Medium
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                                Text {
                                    text: modelData.value
                                    color: Theme.text3
                                    font.family: Theme.familyMono
                                    font.pixelSize: 10
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                            }
                        }

                        // Left edge active indicator — 2px accent bar (allowed by design principles)
                        Rectangle {
                            visible: stepRow.isSelected
                            width: 2
                            height: parent.height - 12
                            radius: 1
                            x: 0
                            anchors.verticalCenter: parent.verticalCenter
                            color: stepRow.catColor
                        }

                        // Hover controls — ↑ ↓ × on the right edge. Visible
                        // when the row (or its sub-areas) has the mouse or is
                        // selected so keyboard-only users still see them.
                        Row {
                            id: ctrlRow
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            opacity: (rowArea.containsMouse
                                      || upArea.containsMouse
                                      || downArea.containsMouse
                                      || delArea.containsMouse
                                      || stepRow.isSelected) ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: Theme.durFast } }

                            Rectangle {
                                width: 22; height: 22; radius: 3
                                color: upArea.containsMouse ? Theme.surface3 : "transparent"
                                Text {
                                    anchors.centerIn: parent
                                    text: "↑"
                                    color: model.index === 0 ? Theme.text3 : Theme.text2
                                    font.family: Theme.familyBody
                                    font.pixelSize: 14
                                }
                                MouseArea {
                                    id: upArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: model.index > 0
                                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: root.moveStepRequested(model.index, model.index - 1)
                                }
                            }
                            Rectangle {
                                width: 22; height: 22; radius: 3
                                color: downArea.containsMouse ? Theme.surface3 : "transparent"
                                Text {
                                    anchors.centerIn: parent
                                    text: "↓"
                                    color: model.index === root.actions.length - 1
                                        ? Theme.text3 : Theme.text2
                                    font.family: Theme.familyBody
                                    font.pixelSize: 14
                                }
                                MouseArea {
                                    id: downArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: model.index < root.actions.length - 1
                                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: root.moveStepRequested(model.index, model.index + 1)
                                }
                            }
                            Rectangle {
                                width: 22; height: 22; radius: 3
                                color: delArea.containsMouse
                                    ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.18)
                                    : "transparent"
                                Text {
                                    anchors.centerIn: parent
                                    text: "×"
                                    color: delArea.containsMouse ? Theme.err : Theme.text2
                                    font.family: Theme.familyBody
                                    font.pixelSize: 16
                                }
                                MouseArea {
                                    id: delArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.deleteStepRequested(model.index)
                                }
                            }
                        }
                    }
                }

                // Add-step footer — opens a Menu of kinds.
                Rectangle {
                    id: addStepRow
                    width: parent.width
                    height: 40
                    color: addArea.containsMouse ? Theme.surface2 : "transparent"
                    Behavior on color { ColorAnimation { duration: Theme.durFast } }

                    // First-time tutorial tooltip. Shown when the
                    // parent flips `showTutorial` true — typically on
                    // a blank workflow that's never been opened on
                    // this machine. Auto-dismisses after 4.5s for
                    // screen readers; users can also × it.
                    TutorialOverlay {
                        anchors.bottom: parent.top
                        anchors.bottomMargin: 4
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "Start by adding a step — try Type text or Press key."
                        visible: root.showTutorial
                        onDismissed: root.tutorialDismissed()
                        z: 10   // float above any neighboring rows
                    }

                    Row {
                        anchors.centerIn: parent
                        spacing: 8
                        Text {
                            text: "+"
                            color: Theme.accent
                            font.family: Theme.familyBody
                            font.pixelSize: 16
                            font.weight: Font.Bold
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: "Add step"
                            color: Theme.text2
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            font.weight: Font.Medium
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: addArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: kindMenu.popup()
                    }

                    WfMenu {
                        id: kindMenu
                        Repeater {
                            model: root._pickableKinds
                            delegate: WfMenuItem {
                                text: modelData.label
                                onTriggered: root.addStepRequested(modelData.kind)
                            }
                        }
                    }
                }
                }  // inner Column (steps + add-step footer)
            }
        }

        // Right — inspector for selected step
        Rectangle {
            width: parent.width - 320 - 16
            height: parent.height
            radius: Theme.radiusMd
            color: Theme.surface
            border.color: Theme.lineSoft
            border.width: 1

            readonly property var sel: (root.selectedIndex >= 0 && root.selectedIndex < root.actions.length)
                ? root.actions[root.selectedIndex] : null
            readonly property color catColor: sel ? Theme.catFor(sel.kind) : Theme.accent

            Column {
                anchors.fill: parent
                anchors.margins: 28
                spacing: 20

                // Header: big icon + kind
                Row {
                    spacing: 18

                    CategoryIcon {
                        kind: parent.parent.parent.sel ? parent.parent.parent.sel.kind : "wait"
                        size: 72
                        hovered: false
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        Text {
                            text: "STEP " + String(root.selectedIndex + 1).padStart(2, "0")
                            color: parent.parent.parent.parent.catColor
                            font.family: Theme.familyMono
                            font.pixelSize: 11
                            font.weight: Font.Bold
                            font.letterSpacing: 1.0
                        }
                        Text {
                            text: parent.parent.parent.parent.sel ? parent.parent.parent.parent.sel.summary : ""
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontXl
                            font.weight: Font.DemiBold
                        }
                        Text {
                            text: parent.parent.parent.parent.sel ? ("kind: " + parent.parent.parent.parent.sel.kind) : ""
                            color: Theme.text3
                            font.family: Theme.familyMono
                            font.pixelSize: Theme.fontSm
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Theme.lineSoft }

                // Value — editable for string- and int-valued kinds; read-only
                // display for flow / multi-int kinds that need a richer editor.
                Column {
                    id: valueSection
                    width: parent.width
                    spacing: 6

                    readonly property var sel: parent.parent.sel
                    readonly property color catColor: parent.parent.catColor

                    Row {
                        spacing: 10
                        width: parent.width
                        Text {
                            text: "VALUE"
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: 10
                            font.weight: Font.Bold
                            font.letterSpacing: 1.0
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            visible: valueSection.sel
                                && valueSection.sel.editable
                                && valueSection.sel.intOnly === true
                            text: valueSection.sel && valueSection.sel.unit
                                ? valueSection.sel.unit
                                : "integer"
                            color: Theme.text3
                            font.family: Theme.familyMono
                            font.pixelSize: 9
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            visible: valueSection.sel && !valueSection.sel.editable
                            text: "edit via KDL"
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: 9
                            font.italic: true
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Rectangle {
                        width: parent.width
                        height: 56
                        radius: Theme.radiusMd
                        color: Qt.rgba(Theme.bg.r, Theme.bg.g, Theme.bg.b, 1)
                        border.color: valueField.activeFocus
                            ? valueSection.catColor
                            : Theme.lineSoft
                        border.width: valueField.activeFocus ? 2 : 1
                        Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

                        // Editable field — visible only when the action's primary
                        // is inline-editable (string- or int-valued kind).
                        TextField {
                            id: valueField
                            visible: valueSection.sel && valueSection.sel.editable
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            verticalAlignment: TextInput.AlignVCenter

                            // Re-sync the field's text whenever the selection or
                            // upstream primary changes — keyed on a synthetic
                            // property so user typing doesn't fight the binding
                            // (text is a plain assignment, not a declarative binding).
                            readonly property var syncKey: [root.selectedIndex,
                                valueSection.sel ? valueSection.sel.rawPrimary : ""]
                            onSyncKeyChanged: {
                                const v = valueSection.sel ? (valueSection.sel.rawPrimary || "") : ""
                                if (valueField.text !== v) valueField.text = v
                            }
                            Component.onCompleted: {
                                valueField.text = valueSection.sel ? (valueSection.sel.rawPrimary || "") : ""
                            }

                            color: Theme.text
                            font.family: Theme.familyMono
                            font.pixelSize: Theme.fontMd
                            selectByMouse: true

                            background: Item {}

                            // IntValidator for int-only kinds so a stray letter
                            // can't turn `click 1` into a broken action.
                            validator: valueSection.sel && valueSection.sel.intOnly
                                ? intValidator : null
                            IntValidator { id: intValidator; bottom: 0 }

                            // Commit on every keystroke so the user doesn't
                            // have to discover that Enter / focus-out is the
                            // commit moment. The 600ms save debounce on the
                            // page coalesces the writes; the dirty pill in
                            // the toolbar lights up immediately.
                            function _commit() {
                                if (!valueSection.sel || !valueSection.sel.editable) return
                                if (text !== valueSection.sel.rawPrimary) {
                                    root.valueEdited(root.selectedIndex, text)
                                }
                            }
                            onTextEdited: _commit()
                            onEditingFinished: _commit()
                            Keys.onReturnPressed: editingFinished()
                            Keys.onEnterPressed:  editingFinished()
                        }

                        // Read-only display for flow-control / multi-int kinds.
                        Text {
                            visible: valueSection.sel && !valueSection.sel.editable
                            anchors.left: parent.left
                            anchors.leftMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            text: valueSection.sel ? valueSection.sel.value : ""
                            color: Theme.text2
                            font.family: Theme.familyMono
                            font.pixelSize: Theme.fontMd
                        }
                    }
                }

                // Real option editors, bound to the selected step's fields.
                Column {
                    id: optionsSection
                    width: parent.width
                    spacing: 10

                    readonly property var sel: parent.parent.sel
                    readonly property color catColor: parent.parent.catColor
                    readonly property var act: sel ? sel.rawAction : null
                    readonly property string rawKind: sel ? sel.rawKind : ""

                    Text {
                        text: "OPTIONS"
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: 10
                        font.weight: Font.Bold
                        font.letterSpacing: 1.0
                    }

                    // Skip this step — inverse of `enabled`.
                    Row {
                        width: parent.width
                        height: 28
                        spacing: 12
                        visible: optionsSection.sel != null

                        Rectangle {
                            id: skipBox
                            readonly property bool checked: optionsSection.sel
                                && optionsSection.sel.enabled === false
                            width: 16; height: 16; radius: 4
                            color: skipBox.checked ? optionsSection.catColor : "transparent"
                            border.color: skipBox.checked ? optionsSection.catColor : Theme.line
                            border.width: 1
                            anchors.verticalCenter: parent.verticalCenter
                            Behavior on color { ColorAnimation { duration: Theme.durFast } }
                            Text {
                                anchors.centerIn: parent
                                visible: skipBox.checked
                                text: "✓"; color: Theme.accentText
                                font.family: Theme.familyBody; font.pixelSize: 11; font.weight: Font.Bold
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const next = !skipBox.checked
                                    root.optionEdited(root.selectedIndex, "enabled", !next)
                                }
                            }
                        }
                        Text {
                            text: "Skip this step"
                            color: Theme.text2
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    // On error — Stop / Continue segmented control.
                    Row {
                        width: parent.width
                        height: 28
                        spacing: 12
                        visible: optionsSection.sel != null

                        Text {
                            text: "On error"
                            color: Theme.text2
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            anchors.verticalCenter: parent.verticalCenter
                            width: 110
                        }
                        SegmentedControl {
                            anchors.verticalCenter: parent.verticalCenter
                            accent: optionsSection.catColor
                            items: [
                                { label: "Stop",     value: "stop" },
                                { label: "Continue", value: "continue" }
                            ]
                            selected: optionsSection.sel ? (optionsSection.sel.onError || "stop") : "stop"
                            onActivated: (v) => root.optionEdited(root.selectedIndex, "on_error", v)
                        }
                    }

                    // --- Kind-specific option rows below ---
                    // Each row is a labelled numeric or boolean editor.
                    // Visibility is gated on `rawKind` so only the relevant
                    // options appear for the selected action.

                    // Key: clear-modifiers checkbox.
                    Row {
                        width: parent.width
                        height: 28
                        spacing: 12
                        visible: optionsSection.rawKind === "wdo_key"

                        Rectangle {
                            id: clearBox
                            readonly property bool checked: optionsSection.act
                                && optionsSection.act.clear_modifiers === true
                            width: 16; height: 16; radius: 4
                            color: clearBox.checked ? optionsSection.catColor : "transparent"
                            border.color: clearBox.checked ? optionsSection.catColor : Theme.line
                            border.width: 1
                            anchors.verticalCenter: parent.verticalCenter
                            Behavior on color { ColorAnimation { duration: Theme.durFast } }
                            Text {
                                anchors.centerIn: parent
                                visible: clearBox.checked
                                text: "✓"; color: Theme.accentText
                                font.family: Theme.familyBody; font.pixelSize: 11; font.weight: Font.Bold
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const next = !clearBox.checked
                                    root.optionEdited(root.selectedIndex,
                                        "action.clear_modifiers", next ? true : null)
                                }
                            }
                        }
                        Text {
                            text: "Clear held modifiers first"
                            color: Theme.text2
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    // Type: delay-ms numeric (per-character).
                    OptionNumberRow {
                        width: parent.width
                        visible: optionsSection.rawKind === "wdo_type"
                        label: "Delay per character"
                        unit: "ms"
                        catColor: optionsSection.catColor
                        value: optionsSection.act && optionsSection.act.delay_ms !== undefined
                            ? optionsSection.act.delay_ms : null
                        placeholder: "0"
                        onCommitted: (n) => root.optionEdited(root.selectedIndex, "action.delay_ms", n)
                    }

                    // Shell: retries.
                    OptionNumberRow {
                        width: parent.width
                        visible: optionsSection.rawKind === "shell"
                        label: "Retries on failure"
                        unit: ""
                        catColor: optionsSection.catColor
                        value: optionsSection.act && optionsSection.act.retries !== undefined
                            ? optionsSection.act.retries : null
                        placeholder: "0"
                        integer: true
                        onCommitted: (n) => root.optionEdited(root.selectedIndex, "action.retries",
                            n === null ? 0 : n)
                    }
                    // Shell: backoff-ms between retries.
                    OptionNumberRow {
                        width: parent.width
                        visible: optionsSection.rawKind === "shell"
                        label: "Backoff between retries"
                        unit: "ms"
                        catColor: optionsSection.catColor
                        value: optionsSection.act && optionsSection.act.backoff_ms !== undefined
                            ? optionsSection.act.backoff_ms : null
                        placeholder: "500"
                        onCommitted: (n) => root.optionEdited(root.selectedIndex, "action.backoff_ms", n)
                    }
                    // Shell: timeout-ms (per attempt wall clock).
                    OptionNumberRow {
                        width: parent.width
                        visible: optionsSection.rawKind === "shell"
                        label: "Timeout"
                        unit: "ms"
                        catColor: optionsSection.catColor
                        value: optionsSection.act && optionsSection.act.timeout_ms !== undefined
                            ? optionsSection.act.timeout_ms : null
                        placeholder: "no limit"
                        onCommitted: (n) => root.optionEdited(root.selectedIndex, "action.timeout_ms", n)
                    }

                    // Wait-window: timeout-ms.
                    OptionNumberRow {
                        width: parent.width
                        visible: optionsSection.rawKind === "wdo_await_window"
                        label: "Timeout"
                        unit: "ms"
                        catColor: optionsSection.catColor
                        value: optionsSection.act && optionsSection.act.timeout_ms !== undefined
                            ? optionsSection.act.timeout_ms : 5000
                        placeholder: "5000"
                        onCommitted: (n) => root.optionEdited(root.selectedIndex, "action.timeout_ms", n)
                    }
                }
            }
        }
    }
}
