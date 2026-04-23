pragma Singleton
import QtQuick

// Runtime visual-style switcher. Cycle with Ctrl+. — three modes to compare.
QtObject {
    // "bold" | "cinematic" | "maximalist"
    property string mode: "cinematic"

    // Convenience booleans derived from mode.
    readonly property bool isBold: mode === "bold"
    readonly property bool isCinematic: mode === "cinematic" || mode === "maximalist"
    readonly property bool isMaximalist: mode === "maximalist"

    // Feature flags — components query these rather than `mode` directly.
    readonly property bool ambientGradient: isCinematic     // background glow tied to workflow
    readonly property bool categoryTintedRow: isCinematic    // row gets a tinted fill by category
    readonly property bool animatedEntry: isCinematic        // staggered fade+slide on load
    readonly property bool rowHoverScale: isCinematic        // slight scale on hover
    readonly property bool richActiveStep: isCinematic       // pulsing glow on the running step
    readonly property bool pageTransitions: isCinematic      // StackView-style fade between pages

    readonly property bool animatedMeshBg: isMaximalist      // breathing mesh gradient behind content
    readonly property bool cursorGlow: isMaximalist          // soft radial glow that follows the cursor
    readonly property bool categoryIcons: isMaximalist       // per-kind glyphs, not just chip text
    readonly property bool chipShimmer: isMaximalist         // chip inner shimmer animation
    readonly property bool deepShadows: isMaximalist         // richer shadow work
    readonly property bool iconHoverSpin: isMaximalist       // icon rotates slightly on hover

    // Display labels for the indicator pill.
    readonly property string label: (
        mode === "bold" ? "BOLD" :
        mode === "cinematic" ? "CINEMATIC" :
        "MAXIMALIST"
    )
    readonly property string nextLabel: (
        mode === "bold" ? "CINEMATIC" :
        mode === "cinematic" ? "MAXIMALIST" :
        "BOLD"
    )

    function cycle() {
        mode = (mode === "bold") ? "cinematic"
             : (mode === "cinematic") ? "maximalist"
             : "bold"
    }
}
