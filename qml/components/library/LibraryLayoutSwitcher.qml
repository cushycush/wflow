import QtQuick
import QtQuick.Controls
import Wflow

// Segmented control for the library's layout preference. Lives in the
// library page header. Ctrl+, cycles.
SegmentedControl {
    items: LibraryLayout.labels.map((label, i) => ({
        label: label,
        value: i
    }))
    selected: LibraryLayout.variant
    onActivated: (v) => LibraryLayout.set(v)
}
