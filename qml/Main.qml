import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Wflow

ApplicationWindow {
    id: root
    width: 1280
    height: 800
    minimumWidth: 880
    minimumHeight: 560
    visible: true
    title: "wflow"
    color: Theme.bg

    property string currentPage: "library"       // "library" | "workflow" | "record"
    property string currentWorkflowId: "p1"

    font.family: Theme.familyBody
    font.pixelSize: Theme.fontBase

    // ========== Keyboard shortcuts ==========
    // Ctrl+.  cycle visual style (bold / cinematic / maximalist)
    Shortcut { sequence: "Ctrl+."; onActivated: VisualStyle.cycle() }
    Shortcut { sequence: "Ctrl+/"; onActivated: VisualStyle.cycle() }
    // Ctrl+,  cycle library layout
    Shortcut { sequence: "Ctrl+,"; onActivated: LibraryLayout.cycle() }
    // Ctrl+;  cycle workflow editor layout
    Shortcut { sequence: "Ctrl+;"; onActivated: WorkflowLayout.cycle() }
    // Ctrl+'  cycle record page layout
    Shortcut { sequence: "Ctrl+'"; onActivated: RecordLayout.cycle() }
    // Ctrl+[  cycle global chrome
    Shortcut { sequence: "Ctrl+["; onActivated: GlobalLayout.cycle() }

    // ========== Shell ==========
    Loader {
        id: chromeLoader
        anchors.fill: parent

        sourceComponent: {
            switch (GlobalLayout.variant) {
            case 0: return sidebarChrome
            case 1: return railChrome
            case 2: return topBarChrome
            case 3: return hybridChrome
            case 4: return floatingChrome
            }
            return sidebarChrome
        }

        // Crossfade on chrome swap
        opacity: 0
        Component.onCompleted: opacity = 1
        onSourceComponentChanged: {
            opacity = 0
            chromeFadeIn.restart()
        }
        Timer {
            id: chromeFadeIn
            interval: 40
            onTriggered: chromeLoader.opacity = 1
        }
        Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    }

    Component {
        id: sidebarChrome
        ChromeSidebar {
            currentPage: root.currentPage
            currentWorkflowId: root.currentWorkflowId
            onNavigate: (page) => { root.currentPage = page; if (page !== "workflow") root.currentWorkflowId = "" }
            onOpenWorkflow: (id) => { root.currentWorkflowId = id; root.currentPage = "workflow" }
            onNewWorkflow: { root.currentWorkflowId = "new-draft"; root.currentPage = "workflow" }
            onRecordRequested: root.currentPage = "record"
        }
    }
    Component {
        id: railChrome
        ChromeRail {
            currentPage: root.currentPage
            currentWorkflowId: root.currentWorkflowId
            onNavigate: (page) => { root.currentPage = page; if (page !== "workflow") root.currentWorkflowId = "" }
            onOpenWorkflow: (id) => { root.currentWorkflowId = id; root.currentPage = "workflow" }
            onNewWorkflow: { root.currentWorkflowId = "new-draft"; root.currentPage = "workflow" }
            onRecordRequested: root.currentPage = "record"
        }
    }
    Component {
        id: topBarChrome
        ChromeTopBar {
            currentPage: root.currentPage
            currentWorkflowId: root.currentWorkflowId
            onNavigate: (page) => { root.currentPage = page; if (page !== "workflow") root.currentWorkflowId = "" }
            onOpenWorkflow: (id) => { root.currentWorkflowId = id; root.currentPage = "workflow" }
            onNewWorkflow: { root.currentWorkflowId = "new-draft"; root.currentPage = "workflow" }
            onRecordRequested: root.currentPage = "record"
        }
    }
    Component {
        id: hybridChrome
        ChromeHybrid {
            currentPage: root.currentPage
            currentWorkflowId: root.currentWorkflowId
            onNavigate: (page) => { root.currentPage = page; if (page !== "workflow") root.currentWorkflowId = "" }
            onOpenWorkflow: (id) => { root.currentWorkflowId = id; root.currentPage = "workflow" }
            onNewWorkflow: { root.currentWorkflowId = "new-draft"; root.currentPage = "workflow" }
            onRecordRequested: root.currentPage = "record"
        }
    }
    Component {
        id: floatingChrome
        ChromeFloating {
            currentPage: root.currentPage
            currentWorkflowId: root.currentWorkflowId
            onNavigate: (page) => { root.currentPage = page; if (page !== "workflow") root.currentWorkflowId = "" }
            onOpenWorkflow: (id) => { root.currentWorkflowId = id; root.currentPage = "workflow" }
            onNewWorkflow: { root.currentWorkflowId = "new-draft"; root.currentPage = "workflow" }
            onRecordRequested: root.currentPage = "record"
        }
    }

    // Dev-only switcher pills in the bottom-right
    StyleBadge {
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.margins: 16
    }
}
