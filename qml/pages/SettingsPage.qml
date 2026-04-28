import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Wflow

// Settings page — accessible from the gear icon in the floating nav bar.
// Lays out grouped sections in a single scrollable column. The page owns
// its own StateController instance; writes go straight to disk via the
// bridge invokables (apply_*), and the page's properties bind back to
// the bridge so external changes (e.g. Ctrl+. theme cycle) reflect here.
Item {
    id: root
    signal close()

    // One controller for the whole page. Don't reach into Theme._state
    // because Theme is a singleton and binding mutations from a regular
    // page can race with its own writes.
    // Reuse Theme's StateController so toggling settings here and
    // toggling them via the chrome (Ctrl+. for theme) stays in lockstep
    // — separate instances would each read from disk on creation, then
    // diverge as the user mutates one or the other.
    readonly property var ctrl: Theme._state

    // Page background mirrors LibraryPage / ExplorePage (transparent so
    // the chrome's DotGrid shows through).
    Item {
        anchors.fill: parent
        anchors.topMargin: 80      // clear the floating nav pill
        anchors.leftMargin: 32
        anchors.rightMargin: 32
        anchors.bottomMargin: 24

        Flickable {
            anchors.fill: parent
            contentHeight: layout.implicitHeight + 48
            contentWidth: width
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: layout
                width: Math.min(720, parent.width)
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.s5

                // ---- Page title ----
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: titleCol.implicitHeight

                    Column {
                        id: titleCol
                        width: parent.width
                        spacing: 4

                        Text {
                            text: "Settings"
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontXl
                            font.weight: Font.DemiBold
                        }
                        Text {
                            text: "Preferences for this install. Stored at " +
                                  ctrl.store_path.replace(/\/workflows$/, "/state.toml") + "."
                            color: Theme.text3
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                            wrapMode: Text.WordWrap
                            width: parent.width
                        }
                    }
                }

                // ---- Appearance ----
                SettingSection {
                    title: "Appearance"
                    Layout.fillWidth: true

                    SettingRow {
                        title: "Theme"
                        subtitle: "Follow the desktop, or pin a mode."

                        SegmentedControl {
                            items: [
                                { label: "Auto",  value: "auto" },
                                { label: "Light", value: "light" },
                                { label: "Dark",  value: "dark" }
                            ]
                            selected: Theme.mode
                            onActivated: (v) => {
                                Theme.mode = v
                                ctrl.apply_theme_mode(v)
                            }
                        }
                    }

                    SettingRow {
                        title: "Reduce motion"
                        subtitle: "Skip transitions and pulses. Helpful for vestibular sensitivity or low-power machines."

                        SettingsToggle {
                            checked: ctrl.reduce_motion
                            onToggled: (v) => Theme.applyReduceMotion(v)
                        }
                    }
                }

                // ---- Library ----
                SettingSection {
                    title: "Library"
                    Layout.fillWidth: true

                    SettingRow {
                        title: "Default sort"
                        subtitle: "How the workflow grid is ordered when you open the Library."

                        SegmentedControl {
                            items: [
                                { label: "Recent",   value: "recent" },
                                { label: "Name",     value: "name" },
                                { label: "Last run", value: "last_run" }
                            ]
                            selected: ctrl.library_sort
                            onActivated: (v) => ctrl.apply_library_sort(v)
                        }
                    }

                    SettingRow {
                        title: "Workflows folder"
                        subtitle: "Where wflow saves your .kdl files."

                        Row {
                            spacing: 8

                            Rectangle {
                                width: pathText.implicitWidth + 18
                                height: 30
                                radius: Theme.radiusSm
                                color: Theme.surface2
                                border.color: Theme.line
                                border.width: 1
                                anchors.verticalCenter: parent.verticalCenter

                                Text {
                                    id: pathText
                                    anchors.centerIn: parent
                                    text: ctrl.store_path
                                    color: Theme.text2
                                    font.family: Theme.familyMono
                                    font.pixelSize: Theme.fontSm
                                    elide: Text.ElideMiddle
                                    width: Math.min(implicitWidth, 360)
                                }
                            }

                            SecondaryButton {
                                text: "Reveal"
                                anchors.verticalCenter: parent.verticalCenter
                                onClicked: ctrl.reveal_store_dir()
                            }
                        }
                    }
                }

                // ---- About ----
                SettingSection {
                    title: "About"
                    Layout.fillWidth: true

                    SettingRow {
                        title: "Version"
                        subtitle: "wflow desktop"

                        Text {
                            text: "0.3.26"
                            color: Theme.text2
                            font.family: Theme.familyMono
                            font.pixelSize: Theme.fontSm
                        }
                    }

                    SettingRow {
                        title: "License"
                        subtitle: "MIT or Apache 2.0, at your option."

                        Text {
                            text: "Open source"
                            color: Theme.text2
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                        }
                    }

                    SettingRow {
                        title: "Made with"
                        subtitle: "Qt 6, cxx-qt, Rust, KDL."

                        Text {
                            text: "wdotool · Hanken Grotesk · Geist Mono"
                            color: Theme.text2
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontSm
                        }
                    }
                }
            }
        }
    }

    // ---- Local component: section card ----
    component SettingSection: Rectangle {
        id: section
        property string title: ""
        default property alias contentChildren: rows.children

        radius: Theme.radiusMd
        color: Theme.surface
        border.color: Theme.line
        border.width: 1
        Layout.fillWidth: true
        implicitHeight: secCol.implicitHeight + 32

        Column {
            id: secCol
            anchors.fill: parent
            anchors.margins: 20
            spacing: 14

            Text {
                text: section.title
                color: Theme.text3
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontXs
                font.letterSpacing: 1.2
                font.weight: Font.Bold
                font.capitalization: Font.AllUppercase
            }

            Column {
                id: rows
                width: parent.width
                spacing: 14
            }
        }
    }

    // ---- Local component: a labelled row with a control on the right ----
    component SettingRow: Item {
        id: row
        property string title: ""
        property string subtitle: ""
        default property alias controlChildren: controlSlot.children

        width: parent.width
        height: Math.max(rowText.implicitHeight, controlSlot.implicitHeight) + 4

        Column {
            id: rowText
            anchors.left: parent.left
            anchors.right: controlSlot.left
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                text: row.title
                color: Theme.text
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontBase
                font.weight: Font.Medium
            }
            Text {
                text: row.subtitle
                color: Theme.text3
                font.family: Theme.familyBody
                font.pixelSize: Theme.fontSm
                wrapMode: Text.WordWrap
                width: parent.width
                visible: text.length > 0
            }
        }

        Item {
            id: controlSlot
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: childrenRect.width
            implicitHeight: childrenRect.height
        }
    }

    // ---- Local component: simple on/off toggle ----
    component SettingsToggle: Rectangle {
        id: toggle
        property bool checked: false
        signal toggled(bool value)

        width: 40
        height: 22
        radius: height / 2
        color: checked ? Theme.accent
            : (toggleArea.containsMouse ? Theme.surface3 : Theme.surface2)
        border.color: checked ? Theme.accent : Theme.line
        border.width: 1
        Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
        Behavior on border.color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }

        Rectangle {
            width: 16
            height: 16
            radius: width / 2
            color: toggle.checked ? Theme.accentText : Theme.text2
            anchors.verticalCenter: parent.verticalCenter
            x: toggle.checked ? toggle.width - width - 3 : 3
            Behavior on x { NumberAnimation { duration: Theme.dur(Theme.durFast); easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: Theme.dur(Theme.durFast) } }
        }

        MouseArea {
            id: toggleArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                toggle.checked = !toggle.checked
                toggle.toggled(toggle.checked)
            }
        }
    }
}
