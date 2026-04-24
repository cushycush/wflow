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

            Column {
                anchors.fill: parent
                anchors.topMargin: 12
                anchors.bottomMargin: 12
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
                        readonly property color catColor: {
                            const t = ({
                                "key": Theme.catKey, "type": Theme.catType, "click": Theme.catClick,
                                "move": Theme.catMove, "scroll": Theme.catScroll, "focus": Theme.catFocus,
                                "wait": Theme.catWait, "shell": Theme.catShell, "notify": Theme.catNotify,
                                "clipboard": Theme.catClip, "note": Theme.catNote
                            })
                            return t[modelData.kind] || Theme.catWait
                        }

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
                                width: parent.width - 20 - 12 - 26 - 12
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
                    }
                }
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
            readonly property color catColor: {
                if (!sel) return Theme.accent
                const t = ({
                    "key": Theme.catKey, "type": Theme.catType, "click": Theme.catClick,
                    "move": Theme.catMove, "scroll": Theme.catScroll, "focus": Theme.catFocus,
                    "wait": Theme.catWait, "shell": Theme.catShell, "notify": Theme.catNotify,
                    "clipboard": Theme.catClip, "note": Theme.catNote
                })
                return t[sel.kind] || Theme.catWait
            }

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

                            onEditingFinished: {
                                if (!valueSection.sel || !valueSection.sel.editable) return
                                if (text !== valueSection.sel.rawPrimary) {
                                    root.valueEdited(root.selectedIndex, text)
                                }
                            }
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

                // Mock option rows
                Column {
                    width: parent.width
                    spacing: 8

                    Text {
                        text: "OPTIONS"
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: 10
                        font.weight: Font.Bold
                        font.letterSpacing: 1.0
                    }
                    Repeater {
                        model: ["Run async", "Abort on error", "Retry up to 3 times"]
                        delegate: Row {
                            width: parent.width
                            height: 32
                            spacing: 12

                            Rectangle {
                                width: 16; height: 16; radius: 4
                                color: index === 0 ? parent.parent.parent.parent.catColor
                                                   : "transparent"
                                border.color: index === 0 ? parent.parent.parent.parent.catColor
                                                          : Theme.lineSoft
                                border.width: 1
                                anchors.verticalCenter: parent.verticalCenter
                                Text {
                                    anchors.centerIn: parent
                                    visible: index === 0
                                    text: "✓"
                                    color: Theme.accentText
                                    font.family: Theme.familyBody
                                    font.pixelSize: 11
                                    font.weight: Font.Bold
                                }
                            }
                            Text {
                                text: modelData
                                color: Theme.text2
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontSm
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }
                }
            }
        }
    }
}
