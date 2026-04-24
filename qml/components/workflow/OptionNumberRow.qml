import QtQuick
import QtQuick.Controls
import Wflow

// One row of the OPTIONS panel: a text label on the left, a small numeric
// TextField on the right. Empty input commits null (meaning "reset to the
// field's default") so shell `timeout` can be cleared back to "no limit".
Item {
    id: root
    property string label: ""
    property string unit: ""
    property string placeholder: ""
    property var value: null             // current numeric value (or null)
    property color catColor: Theme.accent
    property bool integer: false         // integer-only input when true

    signal committed(var value)          // fires with a number or null

    implicitHeight: 28

    readonly property string _displayText: value === null || value === undefined
        ? "" : String(value)

    Row {
        anchors.fill: parent
        spacing: 12

        Text {
            text: root.label
            color: Theme.text2
            font.family: Theme.familyBody
            font.pixelSize: Theme.fontSm
            anchors.verticalCenter: parent.verticalCenter
            width: 180
        }

        Rectangle {
            width: 110
            height: 24
            radius: 4
            color: Theme.surface2
            border.color: tf.activeFocus ? root.catColor : Theme.line
            border.width: tf.activeFocus ? 2 : 1
            anchors.verticalCenter: parent.verticalCenter
            Behavior on border.color { ColorAnimation { duration: Theme.durFast } }

            TextField {
                id: tf
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.text
                placeholderText: root.placeholder
                placeholderTextColor: Theme.text3
                font.family: Theme.familyMono
                font.pixelSize: Theme.fontSm
                selectByMouse: true
                background: Item {}
                validator: DoubleValidator { bottom: 0; decimals: root.integer ? 0 : 3 }

                // Re-sync when the upstream value changes and this field isn't focused.
                readonly property string upstream: root._displayText
                onUpstreamChanged: if (!tf.activeFocus && tf.text !== upstream) tf.text = upstream
                Component.onCompleted: tf.text = root._displayText

                onEditingFinished: {
                    const t = tf.text.trim()
                    if (t === "") {
                        if (root.value !== null && root.value !== undefined) {
                            root.committed(null)
                        }
                        return
                    }
                    const n = root.integer ? parseInt(t, 10) : parseFloat(t)
                    if (isNaN(n) || n < 0) { tf.text = root._displayText; return }
                    if (n !== root.value) root.committed(n)
                }
                Keys.onReturnPressed: editingFinished()
                Keys.onEnterPressed:  editingFinished()
            }
        }

        Text {
            visible: root.unit.length > 0
            text: root.unit
            color: Theme.text3
            font.family: Theme.familyMono
            font.pixelSize: Theme.fontXs
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
