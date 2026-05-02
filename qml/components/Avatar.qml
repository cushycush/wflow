import QtQuick
import Wflow

// Same handle hashes to the same gradient via Theme.gradForHandle.
Rectangle {
    id: root

    property string handle: ""
    property int size: 28
    property string gradKind: ""   // optional explicit override, else hashed from handle

    readonly property var grad: gradKind.length > 0
        ? Theme.gradFor(gradKind)
        : Theme.gradForHandle(handle)
    readonly property string monogram: {
        const s = handle.replace(/^@/, "")
        return s.length > 0 ? s.charAt(0).toUpperCase() : "?"
    }

    width: size
    height: size
    radius: size / 2
    antialiasing: true

    gradient: Gradient {
        GradientStop { position: 0; color: root.grad[0] }
        GradientStop { position: 1; color: root.grad[1] }
    }

    Text {
        anchors.centerIn: parent
        text: root.monogram
        color: "white"
        font.family: Theme.familyBody
        font.weight: Font.Bold
        font.pixelSize: Math.max(9, Math.round(root.size * 0.42))
        // Faint shadow keeps light avatars legible on light gradients.
        style: Text.Raised
        styleColor: Qt.rgba(0, 0, 0, 0.25)
    }
}
