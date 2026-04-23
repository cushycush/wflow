import QtQuick
import QtQuick.Controls
import Wflow

// Dev-only pills in the bottom-right. Show and switch every runtime toggle:
// visual style, global chrome, library layout, workflow layout, record layout.
// Goes away once we lock a final look.
Column {
    id: root
    spacing: 6

    Repeater {
        model: [
            { key: "STYLE",  sc: "Ctrl+." },
            { key: "LIB",    sc: "Ctrl+," },
            { key: "EDIT",   sc: "Ctrl+;" },
            { key: "REC",    sc: "Ctrl+'" }
        ]
        delegate: Rectangle {
            id: pill
            readonly property string cur: {
                switch (modelData.key) {
                case "STYLE": return VisualStyle.label
                case "LIB":   return LibraryLayout.label
                case "EDIT":  return WorkflowLayout.label
                case "REC":   return RecordLayout.label
                }
                return ""
            }
            readonly property string nxt: {
                switch (modelData.key) {
                case "STYLE": return VisualStyle.nextLabel
                case "LIB":   return LibraryLayout.nextLabel
                case "EDIT":  return WorkflowLayout.nextLabel
                case "REC":   return RecordLayout.nextLabel
                }
                return ""
            }

            function cycle() {
                switch (modelData.key) {
                case "STYLE": VisualStyle.cycle();    break
                case "LIB":   LibraryLayout.cycle();  break
                case "EDIT":  WorkflowLayout.cycle(); break
                case "REC":   RecordLayout.cycle();   break
                }
            }

            width: pillRow.implicitWidth + 22
            height: 28
            radius: 14
            color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, 0.92)
            border.color: Theme.lineSoft
            border.width: 1

            opacity: 0
            Component.onCompleted: opacity = 1
            Behavior on opacity { NumberAnimation { duration: 400 } }

            Row {
                id: pillRow
                anchors.centerIn: parent
                spacing: 6

                Text {
                    text: modelData.key
                    color: Theme.text3
                    font.family: Theme.familyBody
                    font.pixelSize: 9
                    font.weight: Font.Bold
                    font.letterSpacing: 0.8
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: pill.cur
                    color: Theme.accent
                    font.family: Theme.familyMono
                    font.pixelSize: 10
                    font.weight: Font.Medium
                    font.letterSpacing: 0.4
                    anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle { width: 1; height: 11; color: Theme.lineSoft; anchors.verticalCenter: parent.verticalCenter }
                Text {
                    text: modelData.sc
                    color: Theme.text3
                    font.family: Theme.familyMono
                    font.pixelSize: 9
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: "→ " + pill.nxt
                    color: Theme.text2
                    font.family: Theme.familyMono
                    font.pixelSize: 9
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: pill.cycle()
            }
        }
    }
}
