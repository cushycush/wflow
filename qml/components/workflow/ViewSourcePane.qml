import QtQuick
import QtQuick.Controls
import Wflow

// Editable KDL view of the current workflow. Slides in from the right
// of the canvas. The text re-encodes as the canvas mutates; edits in
// here parse + apply back to the canvas on a debounce. Syntax
// highlighting runs through a Rust-fed C++ KdlSyntaxHighlighter
// (cpp/kdl_syntax_highlighter.h) attached to the body's text document.
// setFormat() applies char-format ranges to the existing QTextDocument
// without rebuilding it, so the cursor stays put across keystrokes.
Item {
    id: root

    property string kdlText: ""
    // JSON `[[start, len, "kind"], ...]` from
    // `wfCtrl.tokenize_kdl(kdlText)`. Empty / "[]" renders unstyled.
    // Drives the highlighter while the user isn't editing; during
    // edit, the pane re-tokenizes the local buffer per-keystroke and
    // feeds the highlighter directly.
    property string kdlSpansJson: "[]"
    property string copyHint: ""
    // False for fragment view (read-only by design); true on a real
    // workflow.
    property bool editable: false
    // WorkflowController, passed in so the pane can re-tokenize the
    // local buffer per-keystroke and keep new text highlighted in
    // the same way the canonical source is.
    property var workflowController: null
    // Last parse error from an apply attempt. Empty when the pane
    // text either matches the canvas or parses cleanly.
    property string parseError: ""
    readonly property bool hasText: kdlText.length > 0
    readonly property bool _isUnparsed: parseError.length > 0

    // True while the user is actively typing in the pane. Suppresses
    // the upstream rebind so each keystroke doesn't snap the cursor
    // back to position 0. Flips false on focus-loss; the binding
    // then re-applies with the canonical source. With the
    // QSyntaxHighlighter doing live re-coloring via setFormat on
    // the existing QTextDocument, the document itself isn't rebuilt
    // per keystroke and the cursor stays put.
    property bool _editing: false

    // Highlight spans the pane is currently rendering. Tracks
    // `kdlSpansJson` when not editing; tracks the local buffer's
    // tokenization while editing. Set imperatively on textChanged
    // so the binding to `kdlSpansJson` doesn't keep snapping it
    // back during a keystroke burst.
    property string _liveSpansJson: "[]"

    signal closeRequested()
    signal copyRequested()
    // Emitted on the debounced timer after a textChanged burst.
    // Parent calls apply_kdl_source on the WorkflowController and
    // sets parseError from the result.
    signal applyRequested(string kdl)

    Component.onCompleted: _liveSpansJson = kdlSpansJson

    // Track upstream spans when the canvas re-encodes outside an
    // edit burst. During edit we own the property and ignore
    // upstream churn (the apply path will re-fire this once the
    // edit lands).
    onKdlSpansJsonChanged: {
        if (!_editing) _liveSpansJson = kdlSpansJson
    }

    // Snap spans back to canonical on focus-loss. The Binding on
    // body.text fires in the same change and replaces the local
    // draft with kdlText; QSyntaxHighlighter re-applies formats
    // automatically as the document content changes.
    on_EditingChanged: {
        if (!_editing) _liveSpansJson = kdlSpansJson
    }

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusMd
        color: Theme.surface
        border.color: Theme.lineSoft
        border.width: 1

        // Header
        Item {
            id: headerBar
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 1
            height: 44

            Row {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                Text {
                    text: "SOURCE"
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 10
                    font.weight: Font.Bold
                    font.letterSpacing: 1.2
                    anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle {
                    width: 1; height: 12
                    color: Theme.lineSoft
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: root.editable ? "editable" : "read-only"
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    font.weight: Font.Medium
                    anchors.verticalCenter: parent.verticalCenter
                }

                // Unparsed chip. Same chip register as the save-state
                // chip in WorkflowPage's TopBar; live ToolTip carries
                // the parse error so the chip itself stays compact.
                Rectangle {
                    visible: root._isUnparsed
                    anchors.verticalCenter: parent.verticalCenter
                    width: unparsedLbl.implicitWidth + 16
                    height: 22
                    radius: Theme.radiusSm
                    color: Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.18)
                    border.color: Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.45)
                    border.width: 1
                    Text {
                        id: unparsedLbl
                        anchors.centerIn: parent
                        text: "● unparsed"
                        color: Theme.err
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontXs
                        font.weight: Font.DemiBold
                    }
                    HoverHandler { id: unparsedHover }
                    ToolTip.visible: unparsedHover.hovered
                    ToolTip.delay: 200
                    ToolTip.text: root.parseError
                }
            }

            Row {
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                Text {
                    visible: root.copyHint.length > 0
                    text: root.copyHint
                    color: Theme.ok
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    font.weight: Font.Medium
                    anchors.verticalCenter: parent.verticalCenter
                }
                SecondaryButton {
                    text: "⧉ Copy"
                    topPadding: 4
                    bottomPadding: 4
                    leftPadding: 12
                    rightPadding: 12
                    enabled: root.hasText
                    onClicked: root.copyRequested()
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "Copy the full KDL source to the clipboard"
                }
                Item { width: 4; height: 1 }
                IconButton {
                    iconText: "×"
                    compact: true
                    onClicked: root.closeRequested()
                    ToolTip.visible: hovered
                    ToolTip.delay: 400
                    ToolTip.text: "Close the source pane"
                }
            }
        }

        Rectangle {
            anchors.top: headerBar.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 1
            anchors.rightMargin: 1
            height: 1
            color: Theme.lineSoft
        }

        // Body. Plain Flickable + TextEdit because Controls TextArea
        // inside a ScrollView defers its initial layout until the user
        // clicks in — the text exists but doesn't paint until focus.
        Flickable {
            id: scroll
            anchors.top: headerBar.bottom
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: 1
            anchors.leftMargin: 1
            anchors.rightMargin: 1
            anchors.bottomMargin: 1
            clip: true
            contentWidth: body.contentWidth + body.leftPadding + body.rightPadding
            contentHeight: body.contentHeight + body.topPadding + body.bottomPadding
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

            TextEdit {
                id: body
                width: scroll.contentWidth
                height: scroll.contentHeight
                // Plain text throughout. Highlighting comes from the
                // KdlSyntaxHighlighter below, which applies char-format
                // ranges to the QTextDocument without rebuilding it.
                textFormat: TextEdit.PlainText
                readOnly: !root.editable
                wrapMode: TextEdit.NoWrap
                selectByMouse: true
                selectByKeyboard: true
                persistentSelection: true
                font.family: Theme.familyMono
                font.pixelSize: Theme.fontSm
                color: root.hasText ? Theme.text : Theme.text3
                selectionColor: Theme.accentDim
                selectedTextColor: Theme.text
                leftPadding: 16
                rightPadding: 16
                topPadding: 12
                bottomPadding: 16
                // KDL encoder emits 4-space indent (kdl crate default);
                // any literal \t that sneaks in via paste renders the
                // same visual width instead of the default 8-char Qt
                // tab stop.
                tabStopDistance: 4 * Math.ceil(fontMetrics.advanceWidth(" "))

                FontMetrics {
                    id: fontMetrics
                    font.family: body.font.family
                    font.pixelSize: body.font.pixelSize
                }

                // Upstream rebind. Disabled while the user is typing
                // so each keystroke doesn't snap the cursor back to
                // the canonical source. Re-enables on focus-loss; the
                // canonical text snaps in and the highlighter
                // re-applies formats from `_liveSpansJson`, which has
                // already been snapped back to canonical by
                // `on_EditingChanged` above.
                Binding on text {
                    value: root.hasText ? root.kdlText : "(no workflow loaded)"
                    when: !root._editing
                }

                // BeforeItem so our Tab handler runs ahead of Qt's
                // default focus-traversal, which otherwise eats the
                // key and stops `body.insert` from ever firing.
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: (event) => {
                    if (!root.editable) return
                    // Tab inserts 4 spaces (one KDL indent level,
                    // matching what the encoder writes). Done here
                    // instead of relying on tabStopDistance so the
                    // saved KDL stays space-indented without any \t.
                    if (event.key === Qt.Key_Tab
                            && (event.modifiers & ~Qt.ShiftModifier) === 0) {
                        if (!root._editing) root._editing = true
                        event.accepted = true
                        body.insert(body.cursorPosition, "    ")
                        return
                    }
                    // Any other printable key (with no Ctrl/Meta/Alt)
                    // signals start of edit so the upstream rebind
                    // stops fighting the user's cursor.
                    if (event.text && event.text.length > 0
                            && (event.modifiers & ~Qt.ShiftModifier) === 0) {
                        if (!root._editing) root._editing = true
                    }
                }
                onActiveFocusChanged: if (!activeFocus) root._editing = false

                onTextChanged: {
                    if (!root.editable || !root._editing) return
                    if (!root.workflowController) return
                    // Live re-tokenize: keep the highlighter's spans
                    // tracking the local buffer. The tokenizer is
                    // mid-edit tolerant, so partial input still
                    // returns sensible spans (malformed bytes fall
                    // through as plain).
                    const plain = body.getText(0, body.length)
                    root._liveSpansJson =
                        root.workflowController.tokenize_kdl(plain)
                    applyTimer.restart()
                }
            }

            // Hand-written C++ subclass registered from main.rs via
            // bridge::kdl_highlight::qobject::register_kdl_qml_types.
            // Attaches to body's QTextDocument and applies
            // QTextCharFormat ranges via setFormat(); the document
            // itself isn't rebuilt, so the cursor stays where the
            // user left it.
            KdlSyntaxHighlighter {
                id: highlighter
                textDocument: body.textDocument
                spansJson: root._liveSpansJson
                colors: ({
                    "keyword": Theme.kdlColor("keyword"),
                    "node":    Theme.kdlColor("node"),
                    "prop":    Theme.kdlColor("prop"),
                    "string":  Theme.kdlColor("string"),
                    "number":  Theme.kdlColor("number"),
                    "bool":    Theme.kdlColor("bool"),
                    "ident":   Theme.kdlColor("ident"),
                    "punct":   Theme.kdlColor("punct"),
                    "comment": Theme.kdlColor("comment")
                })
            }

            // Debounced parse + apply. Same 600ms cadence as the
            // workflow save timer in WorkflowPage so the two land on
            // a similar rhythm.
            Timer {
                id: applyTimer
                interval: 600
                repeat: false
                onTriggered: {
                    const plain = body.getText(0, body.length)
                    root.applyRequested(plain)
                }
            }
        }
    }
}
