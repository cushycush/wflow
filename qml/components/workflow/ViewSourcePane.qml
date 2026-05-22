import QtQuick
import QtQuick.Controls
import Wflow

// Read-only KDL view of the current workflow. Slides in from the right
// of the canvas. The text re-encodes as the user edits, so the source
// you see always matches what would hit disk on the next save.
Item {
    id: root

    property string kdlText: ""
    // JSON `[[start, len, "kind"], ...]` from
    // `wfCtrl.tokenize_kdl(kdlText)`. Empty / "[]" renders unstyled.
    property string kdlSpansJson: "[]"
    property string copyHint: ""
    readonly property bool hasText: kdlText.length > 0

    signal closeRequested()
    signal copyRequested()

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
                    text: "read-only"
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    font.weight: Font.Medium
                    anchors.verticalCenter: parent.verticalCenter
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
                // Highlighted HTML when we have a workflow; plain
                // text placeholder otherwise so the empty state still
                // tracks Theme.text3.
                textFormat: root.hasText ? TextEdit.RichText : TextEdit.PlainText
                text: root.hasText ? root._kdlHtml : "(no workflow loaded)"
                readOnly: true
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
            }
        }
    }
}
