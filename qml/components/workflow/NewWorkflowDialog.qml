import QtQuick
import QtQuick.Controls
import Wflow

// Modal dialog the user sees when they click `+ New workflow`.
//
// Three tabs:
//   - Blank:    create an empty Untitled workflow and open the editor.
//   - Template: pick from packaged example workflows; instantiates a
//               copy in the user's library.
//   - Record:   navigate to the Record page so the recorder builds the
//               workflow from real input.
//
// The dialog is kept stateless — it emits one of three signals when
// the user confirms, and the caller (LibraryPage) owns the side
// effect (controller calls + page navigation).
Dialog {
    id: root
    title: ""    // Custom header below; default Dialog title bar is
                 // less in-keeping with the brand than our chrome.
    modal: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

    // Centered on the parent window, ~720 wide, capped at 88% of width
    // so it stays comfortable on a 1280×800 default and still works at
    // the 880px minimum.
    width: Math.min(720, parent ? parent.width * 0.88 : 720)
    height: Math.min(560, parent ? parent.height * 0.85 : 560)
    anchors.centerIn: parent

    // Templates list comes from the StateController on demand. The
    // caller sets this when opening — keeps the dialog itself free of
    // singleton lookups.
    property var templates: []

    signal createBlankRequested()
    signal createFromTemplateRequested(string templateId)
    signal recordRequested()

    // Bespoke chrome — Dialog's default header doesn't fit the brand.
    background: Rectangle {
        color: Theme.surface
        radius: Theme.radiusMd
        border.color: Theme.line
        border.width: 1
    }

    // Reset selection state every time the dialog reopens.
    onAboutToShow: {
        tabs.selected = "blank"
        templateList.currentIndex = -1
    }

    contentItem: Item {
        anchors.fill: parent

        Column {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 18

            // Header
            Column {
                width: parent.width
                spacing: 4
                Text {
                    text: "New workflow"
                    color: Theme.text
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontXl
                    font.weight: Font.DemiBold
                }
                Text {
                    text: "Start from blank, pick a template, or record from real input."
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: Theme.fontSm
                }
            }

            // Tabs
            SegmentedControl {
                id: tabs
                anchors.horizontalCenter: parent.horizontalCenter
                accent: Theme.accent
                items: [
                    { label: "Blank",       value: "blank" },
                    { label: "From template", value: "template" },
                    { label: "Record",      value: "record" }
                ]
                selected: "blank"
                onActivated: (v) => tabs.selected = v
            }

            // Tab body — stays at a fixed height so the dialog doesn't
            // jump as the user switches between tabs.
            Item {
                width: parent.width
                height: parent.height - parent.spacing * 3
                       - 60 // header column + heading
                       - 36 // tabs row
                       - 56 // footer button row

                // BLANK
                Column {
                    anchors.fill: parent
                    visible: tabs.selected === "blank"
                    spacing: 12
                    Text {
                        text: "Empty workflow"
                        color: Theme.text
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                    }
                    Text {
                        text: "Create a workflow with no steps. The editor opens with a tip on adding your first step."
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }
                }

                // FROM TEMPLATE
                Item {
                    anchors.fill: parent
                    visible: tabs.selected === "template"

                    Text {
                        id: tplEmpty
                        anchors.centerIn: parent
                        visible: root.templates.length === 0
                        text: "No templates installed."
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                    }

                    ScrollView {
                        anchors.fill: parent
                        visible: root.templates.length > 0
                        clip: true

                        ListView {
                            id: templateList
                            spacing: 6
                            model: root.templates
                            currentIndex: -1
                            delegate: Rectangle {
                                width: ListView.view ? ListView.view.width : 0
                                height: 60
                                radius: 6
                                color: ListView.isCurrentItem
                                    ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.12)
                                    : (rowArea.containsMouse ? Theme.surface2 : "transparent")

                                MouseArea {
                                    id: rowArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: templateList.currentIndex = index
                                    onDoubleClicked: {
                                        templateList.currentIndex = index
                                        root._confirm()
                                    }
                                }

                                Column {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: 14
                                    anchors.rightMargin: 14
                                    spacing: 2
                                    Text {
                                        text: modelData.title || modelData.id
                                        color: Theme.text
                                        font.family: Theme.familyBody
                                        font.pixelSize: Theme.fontSm
                                        font.weight: Font.Medium
                                        elide: Text.ElideRight
                                        width: parent.width
                                    }
                                    Text {
                                        text: modelData.subtitle || ""
                                        color: Theme.text3
                                        font.family: Theme.familyBody
                                        font.pixelSize: Theme.fontXs
                                        elide: Text.ElideRight
                                        width: parent.width
                                        visible: text.length > 0
                                    }
                                }
                            }
                        }
                    }
                }

                // RECORD
                Column {
                    anchors.fill: parent
                    visible: tabs.selected === "record"
                    spacing: 12
                    Text {
                        text: "Record from real input"
                        color: Theme.text
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.Medium
                    }
                    Text {
                        text: "Open the recorder, perform the actions you want to replay, then stop. wflow turns the captured input into a workflow."
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }
                }
            }

            // Footer
            Row {
                width: parent.width
                spacing: 8
                layoutDirection: Qt.RightToLeft

                PrimaryButton {
                    text: tabs.selected === "blank"    ? "Create blank" :
                          tabs.selected === "template" ? "Use template" :
                                                          "Open recorder"
                    enabled: tabs.selected !== "template"
                          || (templateList.currentIndex >= 0 && root.templates.length > 0)
                    onClicked: root._confirm()
                }
                SecondaryButton {
                    text: "Cancel"
                    onClicked: root.close()
                }
            }
        }
    }

    function _confirm() {
        if (tabs.selected === "blank") {
            root.createBlankRequested()
        } else if (tabs.selected === "template") {
            if (templateList.currentIndex < 0) return
            const t = root.templates[templateList.currentIndex]
            if (t && t.id) root.createFromTemplateRequested(t.id)
        } else if (tabs.selected === "record") {
            root.recordRequested()
        }
        root.close()
    }
}
