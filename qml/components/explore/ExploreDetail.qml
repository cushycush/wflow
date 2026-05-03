import QtQuick
import QtQuick.Controls
import Wflow

// Right-side slide-in drawer for a community workflow.
// Shows step preview, safety banner for shell actions, Import + Dry run +
// Discussion. Closes on Esc or on the scrim.
//
// Two data props feed the drawer:
//   wf      — card-shape data the catalog already has (title, handle,
//             slug, description, kinds). Always available once a card
//             is open; hydrates the drawer chrome immediately.
//   detail  — rich JSON populated asynchronously by ExploreController
//             once /api/v0/workflow/:handle/:slug resolves. Carries
//             the parsed step list, install / comment / remix counts,
//             and timestamps. Null until the fetch completes; we fall
//             back to wf-derived placeholders so the drawer never
//             flashes empty.
FocusScope {
    id: root
    property var wf
    property var detail
    property bool loading: false
    property bool open: false
    signal imported(string id)
    signal dryRunRequested(string id)
    signal closed()

    focus: open

    // Human-readable label per action category. The detail JSON
    // carries kind + value; the summary lookup stays in QML so we
    // can localise the wording without round-tripping through Rust.
    readonly property var kindSummary: ({
        "key": "Press key chord",
        "type": "Type text",
        "click": "Click",
        "move": "Move mouse",
        "scroll": "Scroll",
        "focus": "Focus window",
        "wait": "Wait",
        "shell": "Run shell command",
        "notify": "Show notification",
        "clipboard": "Copy to clipboard",
        "note": "Note",
        "repeat": "Repeat block",
        "when": "Conditional (when)",
        "unless": "Conditional (unless)",
        "use": "Reuse fragment"
    })

    // Resolved step list: prefer parsed data when the live detail is
    // in, fall back to the kind-list placeholder for offline / mock
    // rows so the drawer still renders something meaningful before
    // the network resolves.
    function _resolvedSteps() {
        if (root.detail && root.detail.steps && root.detail.steps.length > 0) {
            return root.detail.steps.map((s, i) => ({
                kind: s.kind,
                summary: root.kindSummary[s.kind] || s.kind,
                value: s.value || "",
                note: s.note || ""
            }))
        }
        if (!root.wf || !root.wf.kinds) return []
        const total = root.wf.steps || root.wf.kinds.length
        const out = []
        for (let i = 0; i < total; i++) {
            const k = root.wf.kinds[i % root.wf.kinds.length]
            out.push({
                kind: k,
                summary: root.kindSummary[k] || k,
                value: "",
                note: ""
            })
        }
        return out
    }

    // Format an ISO timestamp as a short relative line — "updated 3
    // days ago", "published Apr 22". Live detail carries them; the
    // mock rows leave them blank.
    function _formatStamp(prefix, iso) {
        if (!iso || iso.length === 0) return ""
        const d = new Date(iso)
        if (isNaN(d.getTime())) return ""
        const now = new Date()
        const ms = now.getTime() - d.getTime()
        const day = 24 * 60 * 60 * 1000
        if (ms < day) {
            const hrs = Math.max(1, Math.floor(ms / (60 * 60 * 1000)))
            return prefix + " " + hrs + (hrs === 1 ? " hour ago" : " hours ago")
        }
        if (ms < 30 * day) {
            const days = Math.floor(ms / day)
            return prefix + " " + days + (days === 1 ? " day ago" : " days ago")
        }
        const months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        const sameYear = d.getFullYear() === now.getFullYear()
        const stamp = months[d.getMonth()] + " " + d.getDate() + (sameYear ? "" : (", " + d.getFullYear()))
        return prefix + " " + stamp
    }

    function _hasShell() {
        if (root.detail && root.detail.steps) {
            return root.detail.steps.some(s => s.kind === "shell")
        }
        return root.wf ? !!root.wf.hasShell : false
    }

    function _stepCount() {
        if (root.detail && root.detail.stepCount > 0) return root.detail.stepCount
        return root.wf ? (root.wf.steps || (root.wf.kinds ? root.wf.kinds.length : 0)) : 0
    }

    function _installCount() {
        if (root.detail) return root.detail.installCount || 0
        return root.wf ? (root.wf.imports || 0) : 0
    }

    function _commentCount() {
        return root.detail ? (root.detail.commentCount || 0) : 0
    }

    function _description() {
        if (root.detail && root.detail.description) return root.detail.description
        return root.wf ? (root.wf.subtitle || "") : ""
    }

    Keys.onEscapePressed: if (root.open) root.closed()

    // Scrim — backed by a dimmed near-black tint so it reads as a real
    // overlay rather than an empty layer. Pure #000 is banned per the
    // design rules; pull the bg tone instead so the scrim picks up
    // whatever subtle hue the active theme uses.
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Theme.bg.r * 0.5, Theme.bg.g * 0.5, Theme.bg.b * 0.5, 1)
        opacity: root.open ? 0.45 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Easing.OutCubic } }
        MouseArea {
            anchors.fill: parent
            enabled: root.open
            onClicked: root.closed()
        }
    }

    // Drawer panel
    Rectangle {
        id: drawer
        width: Math.min(560, root.width - 40)
        height: root.height
        x: root.open ? root.width - width : root.width
        color: Theme.bg
        visible: root.width > 0 && x < root.width - 1
        Behavior on x { NumberAnimation { duration: Theme.dur(Theme.durSlow); easing.type: Easing.OutCubic } }

        // Left hairline
        Rectangle {
            width: 1
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            color: Theme.line
        }

        // Close
        Rectangle {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: 14
            anchors.rightMargin: 14
            width: 32; height: 32; radius: 16
            color: closeArea.containsMouse ? Theme.surface2 : "transparent"
            Behavior on color { ColorAnimation { duration: Theme.durFast } }
            Text {
                anchors.centerIn: parent
                text: "×"
                color: Theme.text2
                font.family: Theme.familyBody
                font.pixelSize: 22
            }
            MouseArea {
                id: closeArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.closed()
            }
        }

        ScrollView {
            anchors.fill: parent
            anchors.topMargin: 0
            anchors.bottomMargin: 88   // leave space for the action bar
            anchors.leftMargin: 1
            contentWidth: availableWidth
            clip: true

            Column {
                id: body
                width: parent.width
                topPadding: 28
                bottomPadding: 28
                leftPadding: 28
                rightPadding: 60
                spacing: 20

                // Category + author line
                Row {
                    spacing: 8

                    Rectangle {
                        readonly property color catColor: Theme.catFor(
                            root.wf && root.wf.kinds && root.wf.kinds.length > 0 ? root.wf.kinds[0] : "wait")
                        width: chipLbl.implicitWidth + 14
                        height: 22
                        radius: 11
                        color: Theme.wash(catColor, 0.14)
                        border.color: Qt.rgba(catColor.r, catColor.g, catColor.b, 0.5)
                        border.width: 1
                        Text {
                            id: chipLbl
                            anchors.centerIn: parent
                            text: root.wf ? root.wf.category : ""
                            color: parent.catColor
                            font.family: Theme.familyMono
                            font.pixelSize: 10
                            font.weight: Font.Bold
                            font.letterSpacing: 0.6
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.wf ? "by @" + root.wf.author : ""
                        color: Theme.text2
                        font.family: Theme.familyMono
                        font.pixelSize: Theme.fontSm
                    }
                }

                // Title
                Text {
                    text: root.wf ? root.wf.title : ""
                    color: Theme.text
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.DemiBold
                    width: body.width - body.leftPadding - body.rightPadding
                    wrapMode: Text.WordWrap
                }

                Text {
                    text: root._description()
                    color: Theme.text2
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontMd
                    lineHeight: 1.4
                    width: body.width - body.leftPadding - body.rightPadding
                    wrapMode: Text.WordWrap
                    visible: text.length > 0
                }

                // Timestamp line — published / updated, both relative.
                // Hidden until the live detail lands so we don't print
                // "published just now" against an empty string.
                Row {
                    spacing: 12
                    visible: root.detail !== null
                    Text {
                        text: root.detail ? root._formatStamp("Published", root.detail.publishedAt) : ""
                        color: Theme.text3
                        font.family: Theme.familyMono
                        font.pixelSize: Theme.fontXs
                        visible: text.length > 0
                    }
                    Text {
                        text: root.detail ? root._formatStamp("Updated", root.detail.updatedAt) : ""
                        color: Theme.text3
                        font.family: Theme.familyMono
                        font.pixelSize: Theme.fontXs
                        visible: text.length > 0
                    }
                }

                // Metric strip
                Row {
                    spacing: 22

                    Column {
                        Text { text: root._installCount().toString()
                               color: Theme.text; font.family: Theme.familyBody
                               font.pixelSize: Theme.fontLg; font.weight: Font.DemiBold }
                        Text { text: "installs"; color: Theme.text3
                               font.family: Theme.familyMono; font.pixelSize: Theme.fontXs }
                    }
                    Column {
                        visible: root.detail !== null
                        Text { text: root._commentCount().toString()
                               color: Theme.text; font.family: Theme.familyBody
                               font.pixelSize: Theme.fontLg; font.weight: Font.DemiBold }
                        Text { text: "comments"; color: Theme.text3
                               font.family: Theme.familyMono; font.pixelSize: Theme.fontXs }
                    }
                    Column {
                        Text { text: root._stepCount().toString()
                               color: Theme.text; font.family: Theme.familyBody
                               font.pixelSize: Theme.fontLg; font.weight: Font.DemiBold }
                        Text { text: "steps"; color: Theme.text3
                               font.family: Theme.familyMono; font.pixelSize: Theme.fontXs }
                    }
                }

                // Safety banner
                Rectangle {
                    visible: root._hasShell()
                    width: body.width - body.leftPadding - body.rightPadding
                    height: bannerCol.implicitHeight + 22
                    radius: Theme.radiusSm
                    color: Qt.rgba(Theme.warn.r, Theme.warn.g, Theme.warn.b, 0.09)
                    border.color: Qt.rgba(Theme.warn.r, Theme.warn.g, Theme.warn.b, 0.4)
                    border.width: 1

                    Row {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 10

                        Rectangle {
                            width: 22; height: 22; radius: 11
                            color: Qt.rgba(Theme.warn.r, Theme.warn.g, Theme.warn.b, 0.2)
                            anchors.verticalCenter: parent.verticalCenter
                            Text {
                                anchors.centerIn: parent
                                text: "›"
                                color: Theme.warn
                                font.family: Theme.familyBody
                                font.pixelSize: 14
                                font.weight: Font.Bold
                            }
                        }

                        Column {
                            id: bannerCol
                            width: parent.width - 22 - 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            Text {
                                text: "Contains shell commands"
                                color: Theme.warn
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontSm
                                font.weight: Font.DemiBold
                            }
                            Text {
                                text: "Review steps below before importing. Use Dry Run to walk through without executing."
                                color: Theme.text2
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontXs
                                lineHeight: 1.3
                                wrapMode: Text.WordWrap
                                width: parent.width
                            }
                        }
                    }
                }

                // Step preview
                Column {
                    width: body.width - body.leftPadding - body.rightPadding
                    spacing: 6

                    Row {
                        spacing: 8
                        Text {
                            text: "STEPS"
                            color: Theme.text3
                            font.family: Theme.familyMono
                            font.pixelSize: 10
                            font.weight: Font.Bold
                            font.letterSpacing: 0.9
                            bottomPadding: 4
                        }
                        Text {
                            visible: root.loading
                            text: "loading…"
                            color: Theme.text3
                            font.family: Theme.familyMono
                            font.pixelSize: 10
                            font.letterSpacing: 0.9
                        }
                    }

                    // Workflow timeline. A faint vertical rail runs the
                    // height of the step list; each step's kind dot
                    // sits on the rail and "lights up" the same way
                    // the chip cascade does on the cards. Reads as
                    // a sequence rather than a list of separate rows
                    // — same visual language as the chips, scaled up
                    // for the drawer where there's room to breathe.
                    Item {
                        id: timeline
                        width: parent.width
                        readonly property real railX: 9
                        readonly property real dotSize: 10
                        readonly property var steps: root._resolvedSteps()
                        height: stepsCol.implicitHeight

                        // The rail itself — a 1px hairline behind the
                        // dots. Sized to span the full step list, with
                        // a 4px tuck top and bottom so the line doesn't
                        // overshoot the first / last dot.
                        Rectangle {
                            visible: timeline.steps.length > 1
                            x: timeline.railX
                            y: 4
                            width: 1
                            height: stepsCol.implicitHeight - 8
                            color: Theme.lineSoft
                        }

                        Column {
                            id: stepsCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            spacing: 14

                            Repeater {
                                model: timeline.steps
                                delegate: Item {
                                    readonly property color dotColor:
                                        Theme.catFor(modelData.kind || "wait")
                                    readonly property bool _hasNote:
                                        (modelData.note || "").length > 0
                                    width: parent.width
                                    height: stepBody.implicitHeight

                                    // Kind dot, painted on the rail.
                                    // 2px ring of bg punches a clean
                                    // hole through the line behind it
                                    // so the dot reads as a node, not
                                    // an overlap.
                                    Rectangle {
                                        x: timeline.railX - timeline.dotSize / 2 + 0.5
                                        y: 4
                                        width: timeline.dotSize
                                        height: timeline.dotSize
                                        radius: width / 2
                                        color: parent.dotColor
                                        border.color: Theme.bg
                                        border.width: 2
                                    }

                                    Column {
                                        id: stepBody
                                        anchors.left: parent.left
                                        anchors.leftMargin: timeline.railX + timeline.dotSize / 2 + 14
                                        anchors.right: parent.right
                                        spacing: 2

                                        Row {
                                            spacing: 8
                                            Text {
                                                text: (index + 1 < 10 ? "0" : "") + (index + 1)
                                                color: Theme.text3
                                                font.family: Theme.familyMono
                                                font.pixelSize: Theme.fontXs
                                                font.letterSpacing: 0.4
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                            Text {
                                                text: modelData.summary
                                                color: Theme.text
                                                font.family: Theme.familyBody
                                                font.pixelSize: Theme.fontSm
                                                font.weight: Font.DemiBold
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }

                                        Text {
                                            text: modelData.value
                                            color: Theme.text2
                                            font.family: Theme.familyMono
                                            font.pixelSize: Theme.fontSm
                                            elide: Text.ElideRight
                                            width: parent.width
                                            visible: text.length > 0
                                        }

                                        Text {
                                            text: modelData.note
                                            color: Theme.text3
                                            font.family: Theme.familyBody
                                            font.italic: true
                                            font.pixelSize: Theme.fontXs
                                            wrapMode: Text.WordWrap
                                            width: parent.width
                                            visible: text.length > 0
                                            topPadding: 2
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Discussion link
                Row {
                    spacing: 6
                    Text {
                        text: "Discussion on web"
                        color: Theme.accent
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.Medium
                    }
                    Text {
                        text: "→"
                        color: Theme.accent
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                    }
                }
            }
        }

        // Sticky action bar at bottom of drawer
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 88
            color: Theme.surface

            Rectangle {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 1
                color: Theme.line
            }

            Row {
                anchors.fill: parent
                anchors.leftMargin: 28
                anchors.rightMargin: 28
                spacing: 10
                layoutDirection: Qt.RightToLeft

                PrimaryButton {
                    text: "Import"
                    anchors.verticalCenter: parent.verticalCenter
                    topPadding: 12
                    bottomPadding: 12
                    leftPadding: 24
                    rightPadding: 24
                    onClicked: if (root.wf) root.imported(root.wf.id)
                }

                SecondaryButton {
                    text: "Dry run"
                    anchors.verticalCenter: parent.verticalCenter
                    topPadding: 12
                    bottomPadding: 12
                    leftPadding: 18
                    rightPadding: 18
                    onClicked: if (root.wf) root.dryRunRequested(root.wf.id)
                }

                Item { width: parent.width - 0; height: 1 }   // pushes report to the left

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Report"
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor }
                }
            }
        }
    }
}
