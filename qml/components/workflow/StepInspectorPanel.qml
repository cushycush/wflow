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
    property int totalSteps: 0
    // Shaped action of the step that runs before / after this one in
    // the linear sequence. Used by the prev/next nav row.
    property var prevAction: null
    property var nextAction: null
    // Full action list — used to populate the predecessor / successor
    // pickers when the user wants to swap who precedes or follows the
    // selected step.
    property var allActions: []
    readonly property color catColor: sel ? Theme.catFor(sel.kind) : Theme.accent

    signal valueEdited(int stepIndex, string newPrimary)
    signal optionEdited(int stepIndex, string path, var value)
    signal closeRequested()
    signal selectStep(int index)
    // Reorder so step at `otherIndex` becomes the immediate
    // predecessor / successor of the currently selected step.
    signal predecessorChosen(int otherIndex)
    signal successorChosen(int otherIndex)
    // Replace the entire condition object on a `when` / `unless`
    // step. cond is { kind, name?, path?, equals? } — passed whole
    // because the kind switch can leave fields stale otherwise.
    signal conditionEdited(int stepIndex, var cond)
    // Toggle the `negate` flag on a conditional, flipping it between
    // `when` (false) and `unless` (true).
    signal negateToggled(int stepIndex, bool negate)
    // Append a new inner step to a flow-control container's
    // (`when`/`unless`/`repeat`) inner sequence with the given kind.
    signal innerStepAdded(int stepIndex, string kind)
    // Drop an inner step at innerIndex from a container.
    signal innerStepDeleted(int stepIndex, int innerIndex)
    // Same pair, but for the `else_steps` branch of a conditional —
    // the false-side path. Conditional-only; repeat ignores these.
    signal elseStepAdded(int stepIndex, string kind)
    signal elseStepDeleted(int stepIndex, int innerIndex)

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
                        width: 22; height: 22; radius: Theme.radiusSm
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
                        spacing: 6
                        Text {
                            text: root.sel ? root.sel.summary : ""
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontLg
                            font.weight: Font.DemiBold
                        }
                        // Kind chip — small category-tinted pill so
                        // the action category reads at a glance and
                        // the inspector header carries the same
                        // chip aesthetic as the breadcrumb / tabs.
                        Rectangle {
                            visible: root.sel != null
                            width: kindChipText.implicitWidth + 14
                            height: 20
                            radius: Theme.radiusSm
                            color: Qt.rgba(root.catColor.r, root.catColor.g, root.catColor.b, 0.18)
                            border.color: Qt.rgba(root.catColor.r, root.catColor.g, root.catColor.b, 0.45)
                            border.width: 1
                            Text {
                                id: kindChipText
                                anchors.centerIn: parent
                                text: root.sel ? root.sel.kind : ""
                                color: root.catColor
                                font.family: Theme.familyMono
                                font.pixelSize: 10
                                font.weight: Font.Bold
                                font.letterSpacing: 0.5
                            }
                        }
                    }
                }

                Rectangle { width: parent.width - 48; height: 1; color: Theme.lineSoft }

                // Sequence navigation — what runs before, what runs
                // after. Click either to jump the inspector + canvas
                // selection to that step. The arrows track wrap state
                // (no prev on step 1, no next on the last step).
                Column {
                    width: parent.width - 48
                    spacing: 6

                    Text {
                        text: "SEQUENCE"
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: 10
                        font.weight: Font.Bold
                        font.letterSpacing: 1.0
                    }

                    Row {
                        width: parent.width
                        spacing: 8

                        // Predecessor tile. Click to jump selection
                        // backwards; the small swap chevron opens a
                        // picker that lets you choose any other step
                        // to be your predecessor (reorders the list).
                        Rectangle {
                            id: prevTile
                            readonly property bool empty: root.prevAction === null
                            width: (parent.width - parent.spacing) / 2
                            height: 60
                            radius: Theme.radiusMd
                            color: empty
                                ? Theme.bg
                                : (prevArea.containsMouse ? Theme.surface2 : Theme.surface)
                            border.color: Theme.lineSoft
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: Theme.durFast } }

                            Column {
                                anchors.fill: parent
                                anchors.margins: 8
                                anchors.rightMargin: 22
                                spacing: 2
                                Text {
                                    text: "← PRECEDED BY"
                                    color: Theme.text3
                                    font.family: Theme.familyBody
                                    font.pixelSize: 9
                                    font.weight: Font.Bold
                                    font.letterSpacing: 1.0
                                }
                                Text {
                                    text: prevTile.empty
                                        ? "(start of workflow)"
                                        : ("step " + String(root.selectedIndex).padStart(2, "0")
                                           + "  ·  " + (root.prevAction.summary || ""))
                                    color: prevTile.empty ? Theme.text3 : Theme.text2
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontXs
                                    font.italic: prevTile.empty
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                            }

                            MouseArea {
                                id: prevArea
                                anchors.fill: parent
                                anchors.rightMargin: 22
                                hoverEnabled: true
                                enabled: !prevTile.empty
                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: root.selectStep(root.selectedIndex - 1)
                            }

                            // Swap chevron — opens picker on click.
                            Rectangle {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.rightMargin: 4
                                width: 18; height: 18; radius: 4
                                color: prevSwapArea.containsMouse ? Theme.surface3 : "transparent"
                                Behavior on color { ColorAnimation { duration: Theme.durFast } }
                                Text {
                                    anchors.centerIn: parent
                                    text: "⇄"
                                    color: Theme.text2
                                    font.family: Theme.familyBody
                                    font.pixelSize: 11
                                }
                                MouseArea {
                                    id: prevSwapArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: prevPicker.popup()
                                    ToolTip.visible: containsMouse
                                    ToolTip.delay: 400
                                    ToolTip.text: "Choose a different predecessor"
                                }
                            }

                            WfMenu {
                                id: prevPicker
                                Repeater {
                                    model: root.allActions
                                    delegate: WfMenuItem {
                                        // Skip self and current predecessor.
                                        visible: model.index !== root.selectedIndex
                                              && model.index !== root.selectedIndex - 1
                                        height: visible ? implicitHeight : 0
                                        text: String(model.index + 1).padStart(2, "0") + "  ·  "
                                              + (modelData ? (modelData.summary || "") : "")
                                        onTriggered: root.predecessorChosen(model.index)
                                    }
                                }
                            }
                        }

                        // Successor tile — mirror of the predecessor.
                        Rectangle {
                            id: nextTile
                            readonly property bool empty: root.nextAction === null
                            width: (parent.width - parent.spacing) / 2
                            height: 60
                            radius: Theme.radiusMd
                            color: empty
                                ? Theme.bg
                                : (nextArea.containsMouse ? Theme.surface2 : Theme.surface)
                            border.color: Theme.lineSoft
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: Theme.durFast } }

                            Column {
                                anchors.fill: parent
                                anchors.margins: 8
                                anchors.leftMargin: 22
                                spacing: 2
                                Text {
                                    text: "FOLLOWED BY →"
                                    color: Theme.text3
                                    font.family: Theme.familyBody
                                    font.pixelSize: 9
                                    font.weight: Font.Bold
                                    font.letterSpacing: 1.0
                                    horizontalAlignment: Text.AlignRight
                                    width: parent.width
                                }
                                Text {
                                    text: nextTile.empty
                                        ? "(end of workflow)"
                                        : ("step " + String(root.selectedIndex + 2).padStart(2, "0")
                                           + "  ·  " + (root.nextAction.summary || ""))
                                    color: nextTile.empty ? Theme.text3 : Theme.text2
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontXs
                                    font.italic: nextTile.empty
                                    elide: Text.ElideRight
                                    width: parent.width
                                    horizontalAlignment: Text.AlignRight
                                }
                            }

                            MouseArea {
                                id: nextArea
                                anchors.fill: parent
                                anchors.leftMargin: 22
                                hoverEnabled: true
                                enabled: !nextTile.empty
                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: root.selectStep(root.selectedIndex + 1)
                            }

                            Rectangle {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: 4
                                width: 18; height: 18; radius: 4
                                color: nextSwapArea.containsMouse ? Theme.surface3 : "transparent"
                                Behavior on color { ColorAnimation { duration: Theme.durFast } }
                                Text {
                                    anchors.centerIn: parent
                                    text: "⇄"
                                    color: Theme.text2
                                    font.family: Theme.familyBody
                                    font.pixelSize: 11
                                }
                                MouseArea {
                                    id: nextSwapArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: nextPicker.popup()
                                    ToolTip.visible: containsMouse
                                    ToolTip.delay: 400
                                    ToolTip.text: "Choose a different successor"
                                }
                            }

                            WfMenu {
                                id: nextPicker
                                Repeater {
                                    model: root.allActions
                                    delegate: WfMenuItem {
                                        visible: model.index !== root.selectedIndex
                                              && model.index !== root.selectedIndex + 1
                                        height: visible ? implicitHeight : 0
                                        text: String(model.index + 1).padStart(2, "0") + "  ·  "
                                              + (modelData ? (modelData.summary || "") : "")
                                        onTriggered: root.successorChosen(model.index)
                                    }
                                }
                            }
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

                // Condition editor for `when` / `unless`. Visible
                // only when the selected step is a conditional. Cond
                // has a kind (window / file / env) plus one or two
                // value fields; the editor commits the whole cond
                // object so a kind change can rebuild the value
                // shape without leaving stale fields.
                Column {
                    id: conditionSection
                    width: parent.width - 48
                    spacing: 10
                    visible: root.sel && root.sel.rawKind === "conditional"

                    readonly property var act: root.sel ? root.sel.rawAction : null
                    readonly property var cond: act && act.cond ? act.cond : { kind: "window", name: "" }
                    readonly property string condKind: cond.kind || "window"

                    Text {
                        text: "CONDITION"
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: 10
                        font.weight: Font.Bold
                        font.letterSpacing: 1.0
                    }

                    // when / unless toggle
                    Row {
                        width: parent.width
                        height: 28
                        spacing: 12

                        Text {
                            text: "Mode"
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
                                { label: "When",   value: false },
                                { label: "Unless", value: true  }
                            ]
                            selected: conditionSection.act && conditionSection.act.negate === true
                            onActivated: (v) => root.negateToggled(root.selectedIndex, v)
                        }
                    }

                    // Condition kind picker
                    Row {
                        width: parent.width
                        height: 28
                        spacing: 12

                        Text {
                            text: "Predicate"
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
                                { label: "Window", value: "window" },
                                { label: "File",   value: "file"   },
                                { label: "Env",    value: "env"    }
                            ]
                            selected: conditionSection.condKind
                            onActivated: (v) => {
                                // Rebuild the cond object for the new
                                // kind so old fields don't linger.
                                let next
                                if (v === "window")    next = { kind: "window", name: conditionSection.cond.name || "" }
                                else if (v === "file") next = { kind: "file",   path: conditionSection.cond.path || "" }
                                else                   next = { kind: "env",    name: conditionSection.cond.name || "" }
                                root.conditionEdited(root.selectedIndex, next)
                            }
                        }
                    }

                    // Predicate value field — label + meaning depend
                    // on the selected kind. window/env use `name`,
                    // file uses `path`, env can also have `equals`.
                    Rectangle {
                        width: parent.width
                        height: 44
                        radius: Theme.radiusMd
                        color: Theme.bg
                        border.color: condValueField.activeFocus ? root.catColor : Theme.lineSoft
                        border.width: condValueField.activeFocus ? 2 : 1
                        Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

                        TextField {
                            id: condValueField
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            verticalAlignment: TextInput.AlignVCenter
                            color: Theme.text
                            font.family: Theme.familyMono
                            font.pixelSize: Theme.fontSm
                            selectByMouse: true
                            background: Item {}
                            placeholderText: conditionSection.condKind === "file"
                                ? "/home/you/.config/example"
                                : conditionSection.condKind === "env"
                                    ? "ENV_VAR_NAME"
                                    : "window title contains…"

                            readonly property var syncKey: [
                                root.selectedIndex,
                                conditionSection.condKind,
                                conditionSection.cond.name || "",
                                conditionSection.cond.path || ""
                            ]
                            onSyncKeyChanged: {
                                const v = conditionSection.condKind === "file"
                                    ? (conditionSection.cond.path || "")
                                    : (conditionSection.cond.name || "")
                                if (text !== v) text = v
                            }
                            Component.onCompleted: {
                                text = conditionSection.condKind === "file"
                                    ? (conditionSection.cond.path || "")
                                    : (conditionSection.cond.name || "")
                            }

                            function _commit() {
                                const k = conditionSection.condKind
                                let next
                                if (k === "window")    next = { kind: "window", name: text }
                                else if (k === "file") next = { kind: "file",   path: text }
                                else                   next = Object.assign({}, conditionSection.cond, { kind: "env", name: text })
                                root.conditionEdited(root.selectedIndex, next)
                            }
                            onTextEdited: _commit()
                            Keys.onReturnPressed: _commit()
                        }
                    }

                    // Env-only `equals=` field. Optional — empty
                    // means "any non-empty value of this var".
                    Rectangle {
                        visible: conditionSection.condKind === "env"
                        width: parent.width
                        height: 44
                        radius: Theme.radiusMd
                        color: Theme.bg
                        border.color: condEqualsField.activeFocus ? root.catColor : Theme.lineSoft
                        border.width: condEqualsField.activeFocus ? 2 : 1
                        Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

                        TextField {
                            id: condEqualsField
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            verticalAlignment: TextInput.AlignVCenter
                            color: Theme.text
                            font.family: Theme.familyMono
                            font.pixelSize: Theme.fontSm
                            selectByMouse: true
                            background: Item {}
                            placeholderText: "equals=… (optional)"

                            readonly property var syncKey: [root.selectedIndex, conditionSection.cond.equals || ""]
                            onSyncKeyChanged: {
                                const v = conditionSection.cond.equals || ""
                                if (text !== v) text = v
                            }
                            Component.onCompleted: {
                                text = conditionSection.cond.equals || ""
                            }

                            function _commit() {
                                const next = {
                                    kind: "env",
                                    name: conditionSection.cond.name || "",
                                }
                                if (text.length > 0) next.equals = text
                                root.conditionEdited(root.selectedIndex, next)
                            }
                            onTextEdited: _commit()
                            Keys.onReturnPressed: _commit()
                        }
                    }
                }

                Rectangle {
                    visible: conditionSection.visible
                    width: parent.width - 48
                    height: 1
                    color: Theme.lineSoft
                }

                // Inner-steps panel for flow-control containers
                // (when / unless / repeat). Renders the parent's
                // child sequence as a vertical list with tiny add /
                // delete affordances. Inner-step editing is via the
                // KDL escape hatch for now; the list at least makes
                // the structure visible from the GUI.
                Column {
                    id: innerStepsSection
                    width: parent.width - 48
                    spacing: 8
                    visible: root.sel
                          && (root.sel.rawKind === "conditional"
                              || root.sel.rawKind === "repeat")

                    readonly property var act: root.sel ? root.sel.rawAction : null
                    readonly property var inner: act && act.steps ? act.steps : []

                    Text {
                        // Conditionals get "TRUE BRANCH" so the
                        // section reads symmetrically with the
                        // FALSE BRANCH section below. Repeat keeps
                        // "INNER STEPS" — there's no true/false
                        // split there, just a loop body.
                        text: (root.sel && root.sel.rawKind === "conditional"
                            ? "TRUE BRANCH  ("
                            : "INNER STEPS  (") + innerStepsSection.inner.length + ")"
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: 10
                        font.weight: Font.Bold
                        font.letterSpacing: 1.0
                    }

                    Repeater {
                        model: innerStepsSection.inner
                        delegate: Rectangle {
                            width: parent.width
                            height: 36
                            radius: Theme.radiusMd
                            color: innerArea.containsMouse ? Theme.surface2 : Theme.bg
                            border.color: Theme.lineSoft
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: Theme.durFast } }

                            Row {
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                anchors.rightMargin: 4
                                spacing: 8

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: String(model.index + 1).padStart(2, "0")
                                    color: Theme.text3
                                    font.family: Theme.familyMono
                                    font.pixelSize: 10
                                    width: 18
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 18 - 8 - 22 - 8
                                    text: {
                                        const a = modelData ? modelData.action : null
                                        if (!a) return ""
                                        return (a.kind || "") + (a.text || a.chord || a.name || a.command || a.path || "" ?
                                            "  ·  " + (a.text || a.chord || a.name || a.command || a.path || "") : "")
                                    }
                                    color: Theme.text2
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontXs
                                    elide: Text.ElideRight
                                }
                                // delete inner
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 22; height: 22; radius: 4
                                    color: innerDelArea.containsMouse
                                        ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.18)
                                        : "transparent"
                                    Text {
                                        anchors.centerIn: parent
                                        text: "×"
                                        color: innerDelArea.containsMouse ? Theme.err : Theme.text2
                                        font.family: Theme.familyBody
                                        font.pixelSize: 14
                                    }
                                    MouseArea {
                                        id: innerDelArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.innerStepDeleted(root.selectedIndex, model.index)
                                    }
                                }
                            }

                            MouseArea {
                                id: innerArea
                                anchors.fill: parent
                                hoverEnabled: true
                            }
                        }
                    }

                    // + Add inner step. Opens the same kind picker
                    // that the rail uses, scoped to non-flow kinds —
                    // inner-of-inner blocks would need a path-based
                    // selection model to edit, which we don't have
                    // yet, so the picker stays leaf-only.
                    Rectangle {
                        width: parent.width
                        height: 32
                        radius: Theme.radiusMd
                        color: addInnerArea.containsMouse ? Theme.surface2 : "transparent"
                        border.color: Theme.lineSoft
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: Theme.durFast } }

                        Row {
                            anchors.centerIn: parent
                            spacing: 6
                            Text {
                                text: "+"
                                color: root.catColor
                                font.family: Theme.familyBody
                                font.pixelSize: 14
                                font.weight: Font.Bold
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: "Add inner step"
                                color: Theme.text2
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontSm
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        MouseArea {
                            id: addInnerArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: addInnerMenu.popup()
                        }

                        WfMenu {
                            id: addInnerMenu
                            Repeater {
                                model: [
                                    { kind: "key",       label: "Key chord"    },
                                    { kind: "type",      label: "Type text"    },
                                    { kind: "click",     label: "Click"        },
                                    { kind: "focus",     label: "Focus window" },
                                    { kind: "wait",      label: "Wait"         },
                                    { kind: "shell",     label: "Shell"        },
                                    { kind: "notify",    label: "Notify"       },
                                    { kind: "clipboard", label: "Clipboard"    },
                                    { kind: "note",      label: "Note"         }
                                ]
                                delegate: WfMenuItem {
                                    text: modelData.label
                                    onTriggered: root.innerStepAdded(root.selectedIndex, modelData.kind)
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    visible: innerStepsSection.visible
                    width: parent.width - 48
                    height: 1
                    color: Theme.lineSoft
                }

                // False-branch (else) panel. Only for conditionals.
                // Mirrors the inner-steps panel shape but operates on
                // `act.else_steps` and emits the elseStep* signals.
                // The canvas doesn't yet render else cards as a
                // separate column (follow-up); for now this is the
                // authoritative editor for the false branch.
                Column {
                    id: elseStepsSection
                    width: parent.width - 48
                    spacing: 8
                    visible: root.sel && root.sel.rawKind === "conditional"

                    readonly property var act: root.sel ? root.sel.rawAction : null
                    readonly property var elseSteps: act && act.else_steps ? act.else_steps : []

                    Text {
                        text: "FALSE BRANCH  (" + elseStepsSection.elseSteps.length + ")"
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: 10
                        font.weight: Font.Bold
                        font.letterSpacing: 1.0
                    }

                    Text {
                        visible: elseStepsSection.elseSteps.length === 0
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: "Steps that run when the condition is false. Empty by default — add one and the engine treats this `when` as a true/false split."
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontXs
                    }

                    Repeater {
                        model: elseStepsSection.elseSteps
                        delegate: Rectangle {
                            width: parent.width
                            height: 36
                            radius: Theme.radiusMd
                            color: elseRowArea.containsMouse ? Theme.surface2 : Theme.bg
                            border.color: Theme.lineSoft
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: Theme.durFast } }

                            Row {
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                anchors.rightMargin: 4
                                spacing: 8

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: String(model.index + 1).padStart(2, "0")
                                    color: Theme.text3
                                    font.family: Theme.familyMono
                                    font.pixelSize: 10
                                    width: 18
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 18 - 8 - 22 - 8
                                    text: {
                                        const a = modelData ? modelData.action : null
                                        if (!a) return ""
                                        return (a.kind || "") + (a.text || a.chord || a.name || a.command || a.path || "" ?
                                            "  ·  " + (a.text || a.chord || a.name || a.command || a.path || "") : "")
                                    }
                                    color: Theme.text2
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontXs
                                    elide: Text.ElideRight
                                }
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 22; height: 22; radius: 4
                                    color: elseDelArea.containsMouse
                                        ? Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.18)
                                        : "transparent"
                                    Text {
                                        anchors.centerIn: parent
                                        text: "×"
                                        color: elseDelArea.containsMouse ? Theme.err : Theme.text2
                                        font.family: Theme.familyBody
                                        font.pixelSize: 14
                                    }
                                    MouseArea {
                                        id: elseDelArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.elseStepDeleted(root.selectedIndex, model.index)
                                    }
                                }
                            }

                            MouseArea {
                                id: elseRowArea
                                anchors.fill: parent
                                hoverEnabled: true
                            }
                        }
                    }

                    Rectangle {
                        width: parent.width
                        height: 32
                        radius: Theme.radiusMd
                        color: addElseArea.containsMouse ? Theme.surface2 : "transparent"
                        border.color: Theme.lineSoft
                        border.width: 1
                        Behavior on color { ColorAnimation { duration: Theme.durFast } }

                        Row {
                            anchors.centerIn: parent
                            spacing: 6
                            Text {
                                text: "+"
                                color: root.catColor
                                font.family: Theme.familyBody
                                font.pixelSize: 14
                                font.weight: Font.Bold
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: "Add else step"
                                color: Theme.text2
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontSm
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        MouseArea {
                            id: addElseArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: addElseMenu.popup()
                        }

                        WfMenu {
                            id: addElseMenu
                            Repeater {
                                model: [
                                    { kind: "key",       label: "Key chord"    },
                                    { kind: "type",      label: "Type text"    },
                                    { kind: "click",     label: "Click"        },
                                    { kind: "focus",     label: "Focus window" },
                                    { kind: "wait",      label: "Wait"         },
                                    { kind: "shell",     label: "Shell"        },
                                    { kind: "notify",    label: "Notify"       },
                                    { kind: "clipboard", label: "Clipboard"    },
                                    { kind: "note",      label: "Note"         }
                                ]
                                delegate: WfMenuItem {
                                    text: modelData.label
                                    onTriggered: root.elseStepAdded(root.selectedIndex, modelData.kind)
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    visible: elseStepsSection.visible
                    width: parent.width - 48
                    height: 1
                    color: Theme.lineSoft
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

                    // Comment — per-step note that lives on the Step's
                    // own `note` field, not as a separate Action::Note
                    // step. Renders inline on the canvas card as an
                    // italic subline. Empty clears the field.
                    Column {
                        width: parent.width
                        spacing: 6
                        visible: root.sel != null

                        Row {
                            spacing: 12
                            width: parent.width
                            Text {
                                text: "Comment"
                                color: Theme.text2
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontSm
                                anchors.verticalCenter: parent.verticalCenter
                                width: 90
                            }
                            Text {
                                text: "annotation, not run"
                                color: Theme.text3
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontXs
                                font.italic: true
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        Rectangle {
                            id: commentBox
                            width: parent.width
                            height: 56
                            radius: 6
                            color: Theme.bg
                            border.color: commentField.activeFocus
                                ? root.catColor
                                : Theme.lineSoft
                            border.width: 1
                            Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

                            TextArea {
                                id: commentField
                                anchors.fill: parent
                                anchors.margins: 8
                                placeholderText: "what does this step do, why is it here…"
                                color: Theme.text
                                placeholderTextColor: Theme.text3
                                selectionColor: Theme.accentWash(0.4)
                                selectedTextColor: Theme.text
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontSm
                                wrapMode: TextEdit.Wrap
                                background: Item {}

                                // The previous selectedIndex we
                                // synced against. Used to tell a
                                // "user clicked a different card"
                                // sync apart from a "this card's
                                // note was updated upstream" sync —
                                // the former always pulls the new
                                // value, the latter respects focus
                                // so in-progress typing isn't
                                // clobbered.
                                property int _lastSyncedIndex: -2

                                readonly property var syncKey: [
                                    root.selectedIndex,
                                    root.sel ? (root.sel.note || "") : ""
                                ]
                                onSyncKeyChanged: {
                                    const incoming = (root.sel && root.sel.note) || ""
                                    const sameStep = root.selectedIndex === _lastSyncedIndex
                                    // Selection changed → always sync.
                                    // Same step but note differs and
                                    // we're focused → keep typing.
                                    if (sameStep && activeFocus) {
                                        _lastSyncedIndex = root.selectedIndex
                                        return
                                    }
                                    if (incoming !== text) text = incoming
                                    _lastSyncedIndex = root.selectedIndex
                                }
                                Component.onCompleted: {
                                    text = (root.sel && root.sel.note) || ""
                                    _lastSyncedIndex = root.selectedIndex
                                }

                                function _commit() {
                                    const v = text || ""
                                    const cur = (root.sel && root.sel.note) || ""
                                    if (v === cur) return
                                    root.optionEdited(root.selectedIndex, "note", v)
                                }
                                onTextChanged: _commit()
                                onEditingFinished: _commit()
                            }
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
