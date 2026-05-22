import QtQuick
import QtQuick.Controls
import Wflow

// Editable KDL view of the current workflow. Slides in from the right
// of the canvas. The text re-encodes as the canvas mutates; edits in
// here parse + apply back to the canvas on a debounce.
Item {
    id: root

    property string kdlText: ""
    // JSON `[[start, len, "kind"], ...]` from
    // `wfCtrl.tokenize_kdl(kdlText)`. Empty / "[]" renders unstyled.
    property string kdlSpansJson: "[]"
    property string copyHint: ""
    // False for fragment view (read-only by design); true on a real
    // workflow.
    property bool editable: false
    // WorkflowController, passed in so the pane can re-tokenize the
    // local buffer per-keystroke and keep new text highlighted in the
    // same way the canonical source is.
    property var workflowController: null
    // Last parse error from an apply attempt. Empty when the pane
    // text either matches the canvas or parses cleanly.
    property string parseError: ""
    readonly property bool hasText: kdlText.length > 0
    readonly property bool _isUnparsed: parseError.length > 0

    // True while the user is actively typing in the pane. Suppresses
    // the upstream rebind so each keystroke doesn't snap the cursor
    // back to position 0. Flips false on focus-loss; the binding then
    // re-applies with the canonical, fully-highlighted source.
    // Interim behavior: existing colored spans stay put during edit;
    // new chars inherit whatever cursor format Qt picks. The proper
    // QSyntaxHighlighter-based live re-highlight is still on the way.
    property bool _editing: false

    signal closeRequested()
    signal copyRequested()
    // Emitted on the debounced timer after a textChanged burst. Parent
    // calls apply_kdl_source on the WorkflowController and sets
    // parseError from the result.
    signal applyRequested(string kdl)

    // Pre-computed HTML for the body. Rebuilds when the source text,
    // the span list, or the active palette changes. Falls back to
    // plain text on any parse failure.
    readonly property string _kdlHtml: _buildHtml(kdlText, kdlSpansJson,
        Theme.palette, Theme.isDark)

    function _escape(s) {
        return s
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
    }

    // Builds a `<pre>`-wrapped HTML body where each highlighted span
    // is wrapped in `<span style="color: ...">`. Anything between
    // spans renders in the default text color. `palette` and `isDark`
    // are unused in the body of the function; they exist as
    // arguments so the property binding re-fires when the user
    // switches palette or light/dark, since Theme.kdlColor reads both.
    function _buildHtml(text, spansJson, palette, isDark) {
        if (!text || text.length === 0) return ""
        let spans = []
        try { spans = JSON.parse(spansJson) } catch (e) { spans = [] }
        if (!Array.isArray(spans)) spans = []

        const family = Theme.familyMono
        const size = Theme.fontSm
        // QML color objects render as `#aarrggbb` when concatenated,
        // which Qt's RichText subset accepts as-is. Cast through
        // `String()` for explicitness — same effective output.
        const baseColor = String(Theme.text)
        const headerOpen = "<pre style=\"font-family: '" + family
            + "'; font-size: " + size + "px; margin: 0; "
            + "white-space: pre; color: " + baseColor + ";\">"
        const headerClose = "</pre>"

        if (spans.length === 0) return headerOpen + root._escape(text) + headerClose

        let buf = headerOpen
        let cursor = 0
        for (let i = 0; i < spans.length; ++i) {
            const s = spans[i]
            const start = s[0] | 0
            const len = s[1] | 0
            const kind = s[2]
            if (start < cursor || start + len > text.length) continue
            if (start > cursor) {
                buf += root._escape(text.substring(cursor, start))
            }
            const color = String(Theme.kdlColor(kind))
            const piece = root._escape(text.substring(start, start + len))
            const style = (kind === "comment")
                ? "color: " + color + "; font-style: italic;"
                : "color: " + color + ";"
            buf += "<span style=\"" + style + "\">" + piece + "</span>"
            cursor = start + len
        }
        if (cursor < text.length) buf += root._escape(text.substring(cursor))
        buf += headerClose
        return buf
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
                // RichText for the highlighted body; PlainText for the
                // empty-state placeholder so Theme.text3 still tracks.
                // We stay in RichText during an edit burst too — the
                // on_EditingChanged handler strips the color spans
                // instead of flipping textFormat, because flipping
                // textFormat after Qt has wrapped the document in its
                // default HTML serialization renders that markup
                // literally.
                textFormat: root.hasText ? TextEdit.RichText : TextEdit.PlainText
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

                // Upstream rebind. Disabled while the user is typing so
                // each keystroke doesn't snap the cursor to position 0.
                // Re-enables on focus-loss; the canonical source then
                // snaps back in with full highlighting (any unparsed
                // local draft is discarded — last-edit-wins).
                Binding on text {
                    value: root.hasText ? root._kdlHtml : "(no workflow loaded)"
                    when: !root._editing
                }

                // BeforeItem so our Tab handler runs ahead of Qt's
                // default focus-traversal, which otherwise eats the key
                // and stops `body.insert` from ever firing.
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

                // Guard against the textChanged feedback loop from our
                // own snapshot-on-edit-start assignment.
                property bool _applyingHighlight: false

                onTextChanged: {
                    if (!root.editable || !root._editing) return
                    if (body._applyingHighlight) return
                    applyTimer.restart()
                }
            }

            // Debounced parse + apply. Same 600ms cadence as the
            // workflow save timer in WorkflowPage so the two land on
            // a similar rhythm.
            Timer {
                id: applyTimer
                interval: 600
                repeat: false
                onTriggered: {
                    // RichText `body.text` is the HTML; getText returns
                    // the raw KDL the user actually typed.
                    const plain = body.getText(0, body.length)
                    root.applyRequested(plain)
                }
            }
        }
    }
}
