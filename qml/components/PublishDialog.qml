import QtQuick
import QtQuick.Controls
import Wflow

// Modal that posts a local workflow to wflows.com via
// ExploreController.publish_workflow. The dialog is the only
// surface that captures publish metadata — description, readme,
// tags, visibility — so the user gets one focused screen instead
// of a multi-step flow.
//
// Caller wires it like:
//   PublishDialog {
//       id: dlg
//       workflowId: "<the local id>"
//       workflowTitle: "Morning sync"
//       onPublishRequested: (id, desc, readme, tagsJson, vis) => {
//           catalog.publish_workflow(id, desc, readme, tagsJson, vis)
//       }
//   }
//   dlg.open()
//
// The host listens to ExploreController.publish_succeeded /
// publish_failed and either flips the dialog into a "shipped"
// success view (showing the public URL) or surfaces the failure
// inline so the user can fix their input and retry.
Dialog {
    id: root
    modal: true
    closePolicy: Popup.CloseOnEscape
    width: 520
    anchors.centerIn: parent

    /// Local workflow id (uuid). Required.
    property string workflowId: ""
    /// Workflow's display title. Read-only here — the published
    /// workflow's title comes from the KDL itself, this is just for
    /// the dialog header.
    property string workflowTitle: ""

    /// Set true while the parent's bridge call is in flight. The
    /// host should bind this to ExploreController.loading. Disables
    /// the Publish button + shows a status line.
    property bool busy: false
    /// Published successfully — flips the dialog into a success
    /// state with the new URL + a Done button. Host sets this in
    /// onPublish_succeeded.
    property bool succeeded: false
    /// Most recent failure reason; empty when none. Renders as a
    /// red banner below the form.
    property string lastError: ""

    /// Set by the host on publish_succeeded so the success view
    /// can show a clickable URL.
    property string publishedHandle: ""
    property string publishedSlug: ""
    property string publishedUrl: ""

    /// Form state.
    property string description: ""
    property string readme: ""
    property string tagsRaw: ""
    property string visibility: "public"

    signal publishRequested(
        string workflowId,
        string description,
        string readme,
        string tagsJson,
        string visibility
    )

    onOpened: {
        // Reset to a clean form on every open. The success state
        // is one-shot — closing + reopening starts fresh.
        succeeded = false
        lastError = ""
        publishedHandle = ""
        publishedSlug = ""
        publishedUrl = ""
        description = ""
        readme = ""
        tagsRaw = ""
        visibility = "public"
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

        // ── Header ──
        Column {
            width: parent.width
            spacing: 4
            Row {
                spacing: 8
                Rectangle {
                    width: 6; height: 6; radius: 3
                    color: Theme.accent
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: root.succeeded ? "PUBLISHED" : "PUBLISH TO WFLOWS.COM"
                    color: Theme.accent
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    font.weight: Font.Bold
                    font.letterSpacing: 1.4
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            Text {
                text: root.succeeded
                    ? "Your workflow is live."
                    : root.workflowTitle
                color: Theme.text
                font.family: Theme.familyDisplay
                font.pixelSize: Theme.fontXl
                font.weight: Font.DemiBold
                font.letterSpacing: -0.2
                wrapMode: Text.WordWrap
                width: parent.width
                elide: Text.ElideRight
            }
        }

        // ── Success view ──
        // Once publish_succeeded fires the host sets `succeeded`,
        // and we hide the form + show the published URL + Done.
        Column {
            visible: root.succeeded
            width: parent.width
            spacing: 14

            Text {
                text: "@" + root.publishedHandle + " / " + root.publishedSlug
                color: Theme.text2
                font.family: Theme.familyMono
                font.pixelSize: Theme.fontMd
                font.weight: Font.DemiBold
                wrapMode: Text.WordWrap
                width: parent.width
            }

            Rectangle {
                visible: root.publishedUrl.length > 0
                width: parent.width
                height: 48
                radius: Theme.radiusSm
                color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.10)
                border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.40)
                border.width: 1
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    text: root.publishedUrl
                    color: Theme.accent
                    font.family: Theme.familyMono
                    font.pixelSize: Theme.fontSm
                    elide: Text.ElideMiddle
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Qt.openUrlExternally(root.publishedUrl)
                }
            }

            Row {
                width: parent.width
                spacing: 8
                layoutDirection: Qt.RightToLeft

                Button {
                    id: doneBtn
                    text: "Done"
                    topPadding: 8
                    bottomPadding: 8
                    leftPadding: 18
                    rightPadding: 18
                    background: Rectangle {
                        radius: Theme.radiusSm
                        color: doneBtn.hovered ? Theme.accentHi : Theme.accent
                        Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    }
                    contentItem: Text {
                        text: doneBtn.text
                        color: Theme.accentText
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.DemiBold
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    onClicked: root.accept()
                }

                SecondaryButton {
                    text: "Open in browser"
                    visible: root.publishedUrl.length > 0
                    onClicked: Qt.openUrlExternally(root.publishedUrl)
                }
            }
        }

        // ── Form ──
        Column {
            visible: !root.succeeded
            width: parent.width
            spacing: 14

            // Description.
            Column {
                width: parent.width
                spacing: 4
                Text {
                    text: "DESCRIPTION (optional)"
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 9
                    font.weight: Font.Bold
                    font.letterSpacing: 0.8
                }
                TextField {
                    id: descField
                    width: parent.width
                    placeholderText: "One line that helps someone scanning the catalog know what this does."
                    text: root.description
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    color: Theme.text
                    placeholderTextColor: Theme.text3
                    background: Rectangle {
                        radius: Theme.radiusSm
                        color: descField.activeFocus
                            ? Theme.surface2
                            : Qt.rgba(Theme.surface2.r, Theme.surface2.g, Theme.surface2.b, 0.5)
                        border.color: descField.activeFocus ? Theme.accent : Theme.lineSoft
                        border.width: 1
                        Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    }
                    onTextChanged: root.description = text
                }
            }

            // Tags.
            Column {
                width: parent.width
                spacing: 4
                Text {
                    text: "TAGS (comma-separated, optional)"
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 9
                    font.weight: Font.Bold
                    font.letterSpacing: 0.8
                }
                TextField {
                    id: tagsField
                    width: parent.width
                    placeholderText: "focus, shell, productivity"
                    text: root.tagsRaw
                    font.family: Theme.familyMono
                    font.pixelSize: Theme.fontSm
                    color: Theme.text
                    placeholderTextColor: Theme.text3
                    background: Rectangle {
                        radius: Theme.radiusSm
                        color: tagsField.activeFocus
                            ? Theme.surface2
                            : Qt.rgba(Theme.surface2.r, Theme.surface2.g, Theme.surface2.b, 0.5)
                        border.color: tagsField.activeFocus ? Theme.accent : Theme.lineSoft
                        border.width: 1
                        Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    }
                    onTextChanged: root.tagsRaw = text
                }
            }

            // Readme — multiline. Folded by default so the form
            // stays short for the common case (no readme); click
            // the "+ Add a readme" link to expand.
            Column {
                id: readmeBlock
                width: parent.width
                spacing: 4

                property bool _expanded: false

                Row {
                    spacing: 8
                    visible: !readmeBlock._expanded
                    Text {
                        text: "+ Add a readme"
                        color: Theme.accent
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: "(markdown supported)"
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: readmeBlock._expanded = true
                    }
                }

                Column {
                    visible: readmeBlock._expanded
                    width: parent.width
                    spacing: 4

                    Text {
                        text: "README (markdown, optional)"
                        color: Theme.text3
                        font.family: Theme.familyMono
                        font.pixelSize: 9
                        font.weight: Font.Bold
                        font.letterSpacing: 0.8
                    }
                    Rectangle {
                        width: parent.width
                        height: 110
                        radius: Theme.radiusSm
                        color: readmeArea.activeFocus
                            ? Theme.surface2
                            : Qt.rgba(Theme.surface2.r, Theme.surface2.g, Theme.surface2.b, 0.5)
                        border.color: readmeArea.activeFocus ? Theme.accent : Theme.lineSoft
                        border.width: 1
                        Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                        ScrollView {
                            anchors.fill: parent
                            anchors.margins: 1
                            clip: true
                            TextArea {
                                id: readmeArea
                                placeholderText: "Setup notes, prerequisites, screenshots — anything someone reading the catalog should know before they install."
                                text: root.readme
                                wrapMode: TextArea.Wrap
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontSm
                                color: Theme.text
                                placeholderTextColor: Theme.text3
                                background: Item { }
                                leftPadding: 10
                                rightPadding: 10
                                topPadding: 8
                                bottomPadding: 8
                                onTextChanged: root.readme = text
                            }
                        }
                    }
                }
            }

            // Visibility — radio-style two-segment toggle.
            Column {
                width: parent.width
                spacing: 4
                Text {
                    text: "VISIBILITY"
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 9
                    font.weight: Font.Bold
                    font.letterSpacing: 0.8
                }
                Row {
                    spacing: 0
                    Repeater {
                        model: [
                            { value: "public", label: "Public",
                              hint: "Lives in /browse, anyone can install." },
                            { value: "draft", label: "Draft",
                              hint: "Only you see it; share via the URL." }
                        ]
                        delegate: Rectangle {
                            readonly property bool isActive: modelData.value === root.visibility
                            width: 130
                            height: 36
                            radius: index === 0 ? 0 : 0
                            color: isActive
                                ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                                : (visArea.containsMouse ? Theme.surface2 : "transparent")
                            border.color: isActive ? Theme.accent : Theme.lineSoft
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                            Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                            Text {
                                anchors.centerIn: parent
                                text: modelData.label
                                color: isActive ? Theme.accent : Theme.text2
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontSm
                                font.weight: isActive ? Font.DemiBold : Font.Medium
                            }
                            MouseArea {
                                id: visArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.visibility = modelData.value
                            }
                        }
                    }
                }
                Text {
                    text: root.visibility === "public"
                        ? "Lives in /browse, anyone can install."
                        : "Only you see it; share via the URL."
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXs
                    topPadding: 2
                }
            }

            // Error banner — shows the most recent failure inline
            // so the user can read + fix without dismissing the
            // dialog.
            Rectangle {
                visible: root.lastError.length > 0
                width: parent.width
                height: errBody.implicitHeight + 18
                radius: Theme.radiusSm
                color: Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.10)
                border.color: Qt.rgba(Theme.err.r, Theme.err.g, Theme.err.b, 0.40)
                border.width: 1
                Text {
                    id: errBody
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    text: root.lastError
                    color: Theme.err
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                    wrapMode: Text.WordWrap
                }
            }

            // Action row.
            Row {
                width: parent.width
                spacing: 8
                layoutDirection: Qt.RightToLeft

                Button {
                    id: pubBtn
                    text: root.busy ? "Publishing…" : "Publish"
                    enabled: !root.busy && root.workflowId.length > 0
                    topPadding: 8
                    bottomPadding: 8
                    leftPadding: 18
                    rightPadding: 18
                    background: Rectangle {
                        radius: Theme.radiusSm
                        color: !pubBtn.enabled
                            ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.4)
                            : (pubBtn.hovered ? Theme.accentHi : Theme.accent)
                        Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
                    }
                    contentItem: Text {
                        text: pubBtn.text
                        color: Theme.accentText
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        font.weight: Font.DemiBold
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    onClicked: {
                        const tags = root.tagsRaw
                            .split(",")
                            .map(t => t.trim())
                            .filter(t => t.length > 0)
                        root.publishRequested(
                            root.workflowId,
                            root.description,
                            root.readme,
                            JSON.stringify(tags),
                            root.visibility
                        )
                    }
                }

                SecondaryButton {
                    text: "Cancel"
                    enabled: !root.busy
                    onClicked: root.reject()
                }
            }
        }
    }
}
