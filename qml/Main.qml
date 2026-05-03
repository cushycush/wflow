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

    property string currentPage: Theme.showExplore ? "explore" : "library"
    // valid values: "library" | "explore" | "workflow" | "record" | "settings"

    // Editor tabs. Each entry is { kind, source } where kind is
    // "workflow" | "fragment" and source is a workflow id or
    // absolute path. Titles live in `docTitles` keyed by source so
    // resolving them doesn't mutate openDocs and tear down the
    // WorkflowPage Repeater.
    property var openDocs: []
    property var docTitles: ({})
    property int activeDocIndex: -1

    readonly property var activeDoc:
        (activeDocIndex >= 0 && activeDocIndex < openDocs.length)
            ? openDocs[activeDocIndex] : null

    function _findDocIndex(kind, source) {
        for (let i = 0; i < openDocs.length; ++i) {
            const d = openDocs[i]
            if (d.kind === kind && d.source === source) return i
        }
        return -1
    }

    function openWorkflowDoc(id) {
        const existing = _findDocIndex("workflow", id)
        if (existing >= 0) {
            activeDocIndex = existing
        } else {
            const next = openDocs.slice()
            next.push({ kind: "workflow", source: id })
            openDocs = next
            activeDocIndex = next.length - 1
        }
        currentPage = "workflow"
    }

    function openFragmentDoc(path, displayName) {
        const existing = _findDocIndex("fragment", path)
        if (existing >= 0) {
            activeDocIndex = existing
        } else {
            const next = openDocs.slice()
            next.push({ kind: "fragment", source: path })
            openDocs = next
            activeDocIndex = next.length - 1
            // Prefer the parent workflow's import-key over the basename.
            if (displayName && displayName.length > 0) {
                _setDocTitle(activeDocIndex, displayName)
            }
        }
        currentPage = "workflow"
    }

    function closeDoc(index) {
        if (index < 0 || index >= openDocs.length) return
        const closed = openDocs[index]
        const next = openDocs.slice()
        next.splice(index, 1)
        openDocs = next
        // Clear so re-opening with the same source starts fresh.
        if (closed && closed.source && root.docTitles[closed.source]) {
            const titles = Object.assign({}, root.docTitles)
            delete titles[closed.source]
            root.docTitles = titles
        }
        if (next.length === 0) {
            activeDocIndex = -1
            currentPage = "library"
        } else if (activeDocIndex >= next.length) {
            activeDocIndex = next.length - 1
        } else if (activeDocIndex > index) {
            activeDocIndex = activeDocIndex - 1
        }
    }

    function activateDoc(index) {
        if (index < 0 || index >= openDocs.length) return
        activeDocIndex = index
        currentPage = "workflow"
    }

    function _setDocTitle(index, title) {
        if (index < 0 || index >= openDocs.length) return
        if (!title || title.length === 0) return
        const source = openDocs[index].source
        if (root.docTitles[source] === title) return
        const next = Object.assign({}, root.docTitles)
        next[source] = title
        root.docTitles = next
    }

    font.family: Theme.familyBody
    font.pixelSize: Theme.fontBase

    // Page-header pickers are primary; these are for keyboard users.
    Shortcut { sequence: "Ctrl+,"; onActivated: LibraryLayout.cycle() }
    Shortcut { sequence: "Ctrl+."; onActivated: Theme.cycleMode() }
    // Mirrors nav-pill order: Library, optional Explore, Record.
    Shortcut { sequence: "Ctrl+1"; onActivated: root.currentPage = "library" }
    Shortcut { sequence: "Ctrl+2"
        onActivated: root.currentPage = Theme.showExplore ? "explore" : "record"
    }
    Shortcut { sequence: "Ctrl+3"
        enabled: Theme.showExplore
        onActivated: root.currentPage = "record"
    }

    StateController { id: introState }

    // ExplorePage owns its own instance for catalog fetches; this
    // one is the deeplink pipe.
    ExploreController {
        id: deeplinkPipe
        onImport_succeeded: (id) => root.openWorkflowDoc(id)
        onImport_failed: (reason) => {
            console.warn("deeplink import failed:", reason)
        }
        // {title, handle, slug, description, stepCount, sourceUrl}.
        onDeeplink_preview_ready: (previewJson) => {
            try {
                const preview = JSON.parse(previewJson)
                deeplinkConfirmDialog.preview = preview
                deeplinkConfirmDialog.open()
            } catch (e) {
                console.warn("deeplink preview parse failed:", e)
            }
        }
    }

    // Consent gate before the bridge writes anything to disk.
    DeeplinkConfirmDialog {
        id: deeplinkConfirmDialog
        anchors.centerIn: parent
        onConfirmed: (sourceUrl) => deeplinkPipe.import_from_url(sourceUrl)
        onCancelled: console.info("deeplink import cancelled by user")
    }

    // wflow://import?source=<URL> arrives as a CLI arg. Decode the
    // source, fetch a preview without writing to disk, and let the
    // user confirm before the install actually happens. A malicious
    // page that opens such a URL in the user's browser shouldn't be
    // able to silently install a workflow on the desktop — the
    // dialog is the one place that consent lives.
    function _resolveDeeplink(deeplinkUrl) {
        const m = /^wflow:\/\/import\?source=([^&]+)/.exec(deeplinkUrl)
        if (!m) {
            console.warn("unknown deeplink shape:", deeplinkUrl)
            return
        }
        const source = decodeURIComponent(m[1])
        deeplinkPipe.fetch_deeplink_preview(source)
    }

    ChromeFloating {
        id: chrome
        anchors.fill: parent
        currentPage: root.currentPage
        openDocs: root.openDocs
        docTitles: root.docTitles
        activeDocIndex: root.activeDocIndex
        onNavigate: (page) => {
            root.currentPage = page
            // Don't clobber openDocs on nav, switching to Library
            // and back should preserve open tabs. Only the
            // activeDocIndex matters for which tab is rendered.
        }
        onOpenWorkflow: (id) => root.openWorkflowDoc(id)
        onOpenFragment: (path, name) => root.openFragmentDoc(path, name)
        onNewWorkflow: root.openWorkflowDoc("new-draft")
        onActivateDoc: (index) => root.activateDoc(index)
        onCloseDoc: (index) => root.closeDoc(index)
        onDocTitleResolved: (index, title) => root._setDocTitle(index, title)
        onRecordRequested: root.currentPage = "record"
        onShowTutorRequested: tutorial.start()
    }

    // First-launch coach overlay. Editor steps need a populated
    // workflow slot, the nav callback opens a new-draft so the
    // chrome shows up.
    TutorialCoach {
        id: tutorial
        stateCtrl: introState
        onNavigateToPage: (page) => {
            root.currentPage = page
            if (page === "workflow" && root.openDocs.length === 0) {
                root.openWorkflowDoc("new-draft")
            }
        }

        steps: [
            {
                title: "Welcome to wflow",
                body: "Shortcuts for Linux. wflow runs sequences of keystrokes, clicks, shell commands, and waits. Visually authored, plain-text on disk. Quick tour: about 30 seconds."
            },
            {
                title: "Pick your look",
                body: "Two brand palettes ship with wflow. Tap one to try it on, the rest of this tour will reskin live. You can swap any time from Settings.",
                paletteChooser: true
            },
            {
                title: "The nav pill",
                body: "The main areas live here, Library, the editor, Record, Settings. Click a tab to switch.",
                getTarget: () => chrome.pillContainer,
                placement: "below"
            },
            {
                title: "Your library",
                body: "Saved workflows show up as cards. Click any card to open it in the editor; right-click for Duplicate / Delete.",
                page: "library",
                getTarget: () => chrome.libraryPage,
                placement: "auto",
                scrim: false
            },
            {
                title: "Folders organize them",
                body: "Drag a card onto a folder tile to move it in. Type 'a/b' in '+ New folder' to nest folders.",
                page: "library",
                getTarget: () => chrome.libraryPage.folderRail,
                placement: "right"
            },
            {
                title: "Start a workflow",
                body: "Hit + New to start blank or pick a template. The Record tab in the floating pill captures real input if you'd rather transcribe one.",
                page: "library",
                getTarget: () => chrome.libraryPage.topBar,
                placement: "below"
            },
            {
                title: "The editor",
                body: "Once you open a workflow, the editor appears here. Drag steps from a palette on the left, see them as cards on a canvas, click any step to edit details in a panel that slides in from the right.",
                page: "workflow",
                getTarget: () => chrome.workflowSlot,
                placement: "auto",
                scrim: false
            },
            {
                title: "▶ Run plays it back",
                body: "The Run button at the top of the editor plays the workflow start to finish. Each card's status dot pulses green while it's firing, then settles to green / red / grey for ok / error / skipped."
            },
            {
                title: "⏯ Debug walks you through it",
                body: "Hit Debug instead of Run and the engine pauses between every step, Step advances one action, Continue resumes, Stop bails. Inner steps inside a Repeat each get their own dot, so you can see the loop iterate."
            },
            {
                title: "Selection + grouping",
                body: "Shift- or Ctrl-click cards to multi-select; shift- or ctrl-drag empty canvas to lasso. Alt-drag to draw a coloured group rectangle behind cards, purely visual, the engine ignores them.",
                page: "workflow",
                getTarget: () => chrome.workflowSlot,
                placement: "auto",
                scrim: false
            },
            {
                title: "Reuse with imports",
                body: "Drop a `use NAME` step to splice in another workflow file. The card gets a → button that opens the fragment in a new tab so you can edit it without leaving the editor."
            },
            {
                title: "● Record captures input",
                body: "Click the big button to arm, perform the task, then click again to stop. wflow transcribes your keystrokes, clicks, and window-focus changes into a saved workflow. Esc cancels.",
                page: "record",
                getTarget: () => chrome.recordPage.recordSurface,
                placement: "auto",
                scrim: false
            },
            {
                title: "Settings",
                body: "Theme, motion, default sort, workflows folder. All here behind the gear.",
                page: "library",
                getTarget: () => chrome.settingsButton,
                placement: "below"
            },
            {
                title: "You're set",
                body: "Click + New on the Library page to start your first workflow, or hit ● Record to capture one from real input. Settings has a button to replay this tour any time."
            }
        ]
    }

    Component.onCompleted: {
        // Bumping the tour key (intro_tour_v2 → v3) replays once when
        // major editor features land.
        if (!introState.tutorial_seen("intro_tour_v3")) {
            // Two ticks so first page transition settles before the
            // coach overlay reads target rects.
            Qt.callLater(() => Qt.callLater(tutorial.start))
        }
        // Cold-start deeplink (env var). Cleared after read.
        Qt.callLater(() => {
            const url = deeplinkPipe.take_pending_deeplink()
            if (url && url.length > 0) {
                _resolveDeeplink(url)
            }
        })
    }
}
