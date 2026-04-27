import QtQuick
import QtQuick.Controls
import Wflow

// Slide-in inspector for a selected step. Pulled out of the original
// SplitInspector's right pane so the same editor shape (header,
// primary value, kind-specific options) can hang off the canvas
// editor's right edge with a slide animation, rather than being
// half of a hard-split layout.
Item {
    id: root
    property var sel: null
    property int selectedIndex: -1
    readonly property color catColor: sel ? Theme.catFor(sel.kind) : Theme.accent

    signal valueEdited(int stepIndex, string newPrimary)
    signal optionEdited(int stepIndex, string path, var value)
    signal closeRequested()

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusMd
        color: Theme.surface
        border.color: Theme.lineSoft
        border.width: 1

        ScrollView {
            anchors.fill: parent
            anchors.margins: 1
            clip: true
            contentWidth: availableWidth

            Column {
                width: parent.width
                padding: 24
                spacing: 18

                // Header row — small kind label + close affordance
                Item {
                    width: parent.width - 48
                    height: 24

                    Row {
                        spacing: 8
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                            text: "STEP " + (root.sel ? String(root.selectedIndex + 1).padStart(2, "0") : "")
                            color: root.catColor
                            font.family: Theme.familyMono
                            font.pixelSize: 10
                            font.weight: Font.Bold
                            font.letterSpacing: 1.0
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Rectangle {
                            width: 1; height: 12
                            color: Theme.lineSoft
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: root.sel ? root.sel.kind.toUpperCase() : ""
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: 10
                            font.weight: Font.Bold
                            font.letterSpacing: 1.2
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Rectangle {
                        id: closeBtn
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22; height: 22; radius: 11
                        color: closeArea.containsMouse ? Theme.surface2 : "transparent"
                        Behavior on color { ColorAnimation { duration: Theme.durFast } }
                        Text {
                            anchors.centerIn: parent
                            text: "×"
                            color: Theme.text2
                            font.family: Theme.familyBody
                            font.pixelSize: 16
                        }
                        MouseArea {
                            id: closeArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.closeRequested()
                        }
                    }
                }

                // Big icon + summary
                Row {
                    spacing: 16
                    width: parent.width - 48

                    CategoryIcon {
                        kind: root.sel ? root.sel.kind : "wait"
                        size: 56
                        hovered: false
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        Text {
                            text: root.sel ? root.sel.summary : ""
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontLg
                            font.weight: Font.DemiBold
                        }
                        Text {
                            text: root.sel ? ("kind: " + root.sel.kind) : ""
                            color: Theme.text3
                            font.family: Theme.familyMono
                            font.pixelSize: Theme.fontXs
                        }
                    }
                }

                Rectangle { width: parent.width - 48; height: 1; color: Theme.lineSoft }

                // Value editor
                Column {
                    id: valueSection
                    width: parent.width - 48
                    spacing: 6

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
                            visible: root.sel
                                && root.sel.editable
                                && root.sel.intOnly === true
                            text: root.sel && root.sel.unit
                                ? root.sel.unit
                                : "integer"
                            color: Theme.text3
                            font.family: Theme.familyMono
                            font.pixelSize: 9
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            visible: root.sel && !root.sel.editable
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
                        height: 52
                        radius: Theme.radiusMd
                        color: Theme.bg
                        border.color: valueField.activeFocus ? root.catColor : Theme.lineSoft
                        border.width: valueField.activeFocus ? 2 : 1
                        Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

                        TextField {
                            id: valueField
                            visible: root.sel && root.sel.editable
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            verticalAlignment: TextInput.AlignVCenter

                            readonly property var syncKey: [root.selectedIndex,
                                root.sel ? root.sel.rawPrimary : ""]
                            onSyncKeyChanged: {
                                const v = root.sel ? (root.sel.rawPrimary || "") : ""
                                if (valueField.text !== v) valueField.text = v
                            }
                            Component.onCompleted: {
                                valueField.text = root.sel ? (root.sel.rawPrimary || "") : ""
                            }

                            color: Theme.text
                            font.family: Theme.familyMono
                            font.pixelSize: Theme.fontMd
                            selectByMouse: true
                            background: Item {}

                            validator: root.sel && root.sel.intOnly ? intValidator : null
                            IntValidator { id: intValidator; bottom: 0 }

                            function _commit() {
                                if (!root.sel || !root.sel.editable) return
                                if (text !== root.sel.rawPrimary) {
                                    root.valueEdited(root.selectedIndex, text)
                                }
                            }
                            onTextEdited: _commit()
                            onEditingFinished: _commit()
                            Keys.onReturnPressed: editingFinished()
                            Keys.onEnterPressed:  editingFinished()
                        }

                        Text {
                            visible: root.sel && !root.sel.editable
                            anchors.left: parent.left
                            anchors.leftMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.sel ? root.sel.value : ""
                            color: Theme.text2
                            font.family: Theme.familyMono
                            font.pixelSize: Theme.fontMd
                        }
                    }
                }

                // Options
                Column {
                    id: optionsSection
                    width: parent.width - 48
                    spacing: 10

                    readonly property var act: root.sel ? root.sel.rawAction : null
                    readonly property string rawKind: root.sel ? root.sel.rawKind : ""

                    Text {
                        text: "OPTIONS"
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: 10
                        font.weight: Font.Bold
                        font.letterSpacing: 1.0
                    }

                    // Skip this step
                    Row {
                        width: parent.width
                        height: 28
                        spacing: 12
                        visible: root.sel != null

                        Rectangle {
                            id: skipBox
                            readonly property bool checked: root.sel && root.sel.enabled === false
                            width: 16; height: 16; radius: 4
                            color: checked ? root.catColor : "transparent"
                            border.color: checked ? root.catColor : Theme.line
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

                    // On error
                    Row {
                        width: parent.width
                        height: 28
                        spacing: 12
                        visible: root.sel != null

                        Text {
                            text: "On error"
                            color: Theme.text2
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            anchors.verticalCenter: parent.verticalCenter
                            width: 90
                        }
                        SegmentedControl {
                            anchors.verticalCenter: parent.verticalCenter
                            accent: root.catColor
                            items: [
                                { label: "Stop",     value: "stop" },
                                { label: "Continue", value: "continue" }
                            ]
                            selected: root.sel ? (root.sel.onError || "stop") : "stop"
                            onActivated: (v) => root.optionEdited(root.selectedIndex, "on_error", v)
                        }
                    }

                    // Key: clear-modifiers
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
                            color: checked ? root.catColor : "transparent"
                            border.color: checked ? root.catColor : Theme.line
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

                    OptionNumberRow {
                        width: parent.width
                        visible: optionsSection.rawKind === "wdo_type"
                        label: "Delay per character"
                        unit: "ms"
                        catColor: root.catColor
                        value: optionsSection.act && optionsSection.act.delay_ms !== undefined
                            ? optionsSection.act.delay_ms : null
                        placeholder: "0"
                        onCommitted: (n) => root.optionEdited(root.selectedIndex, "action.delay_ms", n)
                    }

                    OptionNumberRow {
                        width: parent.width
                        visible: optionsSection.rawKind === "shell"
                        label: "Retries on failure"
                        unit: ""
                        catColor: root.catColor
                        value: optionsSection.act && optionsSection.act.retries !== undefined
                            ? optionsSection.act.retries : null
                        placeholder: "0"
                        integer: true
                        onCommitted: (n) => root.optionEdited(root.selectedIndex, "action.retries",
                            n === null ? 0 : n)
                    }
                    OptionNumberRow {
                        width: parent.width
                        visible: optionsSection.rawKind === "shell"
                        label: "Backoff between retries"
                        unit: "ms"
                        catColor: root.catColor
                        value: optionsSection.act && optionsSection.act.backoff_ms !== undefined
                            ? optionsSection.act.backoff_ms : null
                        placeholder: "500"
                        onCommitted: (n) => root.optionEdited(root.selectedIndex, "action.backoff_ms", n)
                    }
                    OptionNumberRow {
                        width: parent.width
                        visible: optionsSection.rawKind === "shell"
                        label: "Timeout"
                        unit: "ms"
                        catColor: root.catColor
                        value: optionsSection.act && optionsSection.act.timeout_ms !== undefined
                            ? optionsSection.act.timeout_ms : null
                        placeholder: "no limit"
                        onCommitted: (n) => root.optionEdited(root.selectedIndex, "action.timeout_ms", n)
                    }

                    OptionNumberRow {
                        width: parent.width
                        visible: optionsSection.rawKind === "wdo_await_window"
                        label: "Timeout"
                        unit: "ms"
                        catColor: root.catColor
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
