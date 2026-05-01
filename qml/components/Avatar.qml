import QtQuick
import Wflow

// Gradient-filled circular monogram used everywhere a person is
// referenced (workflow cards, activity feed, leaderboard).
//
//   Avatar { handle: "@alaina" }                  // sm by default
//   Avatar { handle: "@alaina"; size: 36 }        // lg
//   Avatar { handle: "@gpu_kid"; gradKind: "lime" }   // explicit override
//
// Color comes from Theme.gradForHandle() so the same handle always
// renders the same gradient.
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

    // The earlier inner-highlight strip got clipped to the bounding
    // rect, not the circle, so its left/right tips poked past the
    // round edge and read as a faint horizontal box-line on top of
    // light card backgrounds. Removed in favor of a clean fill.

    Text {
        anchors.centerIn: parent
        text: root.monogram
        color: "white"
        font.family: Theme.familyBody
        font.weight: Font.Bold
        font.pixelSize: Math.max(9, Math.round(root.size * 0.42))
        // Faint shadow so light avatars stay legible against bright
        // surrounding gradient stops.
        style: Text.Raised
        styleColor: Qt.rgba(0, 0, 0, 0.25)
    }
}
