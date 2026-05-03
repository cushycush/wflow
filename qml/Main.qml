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

    // Open documents — one per tab in the workflow editor. Each
    // entry is `{ kind, source }`:
    //   kind   = "workflow" | "fragment"
    //   source = workflow id (kind==workflow) or absolute file path
    //            (kind==fragment)
    // The empty array means no editor tabs are open; opening a
    // workflow from Library appends (or activates an existing
    // matching tab) and switches to currentPage="workflow".
    //
    // Tab titles live in the parallel `docTitles` map keyed by
    // source so that resolving a title from the loaded workflow
    // doesn't mutate openDocs and tear down the WorkflowPage
    // Repeater. Display lookup: docTitles[d.source] || d.source.
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
            // Seed the title — fragment names come from the parent
            // workflow's import key, which is more meaningful than
            // the file's basename.
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
        // Drop the cached title for this source so a later
        // openWorkflowDoc with the same id starts fresh.
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

    // Segmented pickers in each page header are the primary control; these
    // shortcuts are for keyboard users.
    Shortcut { sequence: "Ctrl+,"; onActivated: LibraryLayout.cycle() }
    Shortcut { sequence: "Ctrl+."; onActivated: Theme.cycleMode() }
    // Ctrl+N follows the current nav-pill order. Editor is no longer
    // a top-level page (you drill in from Library), so the shortcut
    // list mirrors the pill — Library, optional Explore, Record.
    Shortcut { sequence: "Ctrl+1"; onActivated: root.currentPage = "library" }
    Shortcut { sequence: "Ctrl+2"
        onActivated: root.currentPage = Theme.showExplore ? "explore" : "record"
    }
    Shortcut { sequence: "Ctrl+3"
        enabled: Theme.showExplore
        onActivated: root.currentPage = "record"
    }

    StateController { id: introState }

    // AuthController lives on Theme as Theme._auth so both Main.qml
    // and SettingsPage share one instance (the pending nonce minted
    // by start_sign_in has to be visible to the deeplink-driven
    // complete_sign_in). Connections wires the lifecycle signals
    // here; SettingsPage drives the UI off Theme._auth.state.
    Connections {
        target: Theme._auth
        function onSign_in_succeeded(handle) {
            console.info("signed in as @" + handle)
        }
        function onSign_in_failed(reason) {
            console.warn("sign-in failed:", reason)
        }
        function onSigned_out_event() {
            console.info("signed out")
        }
    }

    // Singleton ExploreController for deep-link handoff. ExplorePage
    // owns its own instance for catalog fetches; this one is just a
    // thin pipe for the wflow:// import URL captured at startup.
    ExploreController {
        id: deeplinkPipe
        onImport_succeeded: (id) => root.openWorkflowDoc(id)
        onImport_failed: (reason) => {
            console.warn("deeplink import failed:", reason)
        }
        // Preview comes back as a JSON string from the bridge —
        // {title, handle, slug, description, stepCount, sourceUrl}.
        // Parse, hand off to the dialog, let the user confirm or
        // cancel before any disk write happens.
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

    // Confirm dialog gating the wflow:// import flow. The bridge
    // fetches metadata first (no disk write), this dialog renders
    // it, the user accepts or cancels. On accept we call
    // import_from_url with the original source URL; the bridge
    // re-fetches and writes through the same path that was running
    // unchallenged before.
    DeeplinkConfirmDialog {
        id: deeplinkConfirmDialog
        anchors.centerIn: parent
        onConfirmed: (sourceUrl) => deeplinkPipe.import_from_url(sourceUrl)
        onCancelled: console.info("deeplink import cancelled by user")
    }

    // wflow:// scheme handler. Two shapes today:
    //
    //   wflow://import?source=<URL>
    //     Workflow import. Fetch a preview without writing to disk,
    //     pop the confirm dialog, install on accept. The dialog is
    //     the consent gate — without it a malicious page could
    //     silently land a workflow.
    //
    //   wflow://auth/callback?nonce=<nonce>&token=<token>
    //     Sign-in completion. AuthController verifies the nonce
    //     against the one it minted at start_sign_in and refuses any
    //     mismatch — same defense against a hostile page firing this
    //     URL at us with an attacker-controlled token.
    function _resolveDeeplink(deeplinkUrl) {
        const importMatch = /^wflow:\/\/import\?source=([^&]+)/.exec(deeplinkUrl)
        if (importMatch) {
            const source = decodeURIComponent(importMatch[1])
            deeplinkPipe.fetch_deeplink_preview(source)
            return
        }
        const authMatch = /^wflow:\/\/auth\/callback\?(.+)$/.exec(deeplinkUrl)
        if (authMatch) {
            const params = _parseQuery(authMatch[1])
            const nonce = params.nonce || ""
            const token = params.token || ""
            if (!nonce || !token) {
                console.warn("auth callback missing nonce or token")
                return
            }
            Theme._auth.complete_sign_in(nonce, token)
            return
        }
        console.warn("unknown deeplink shape:", deeplinkUrl)
    }

    function _parseQuery(qs) {
        const out = ({})
        for (const part of qs.split("&")) {
            const eq = part.indexOf("=")
            if (eq < 0) continue
            const k = decodeURIComponent(part.substring(0, eq))
            const v = decodeURIComponent(part.substring(eq + 1))
            out[k] = v
        }
        return out
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
            // Don't clobber openDocs on nav — switching to Library
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

    // First-launch tutorial. Coach-mark style — overlays the live
    // app and animates between targets as the user advances. Each
    // step is a single focused idea anchored to the relevant UI
    // element; auto-navigates to the right page first when needed.
    // Marked seen on Skip / Finish so subsequent launches go
    // straight to Library.
    //
    // Editor steps need a populated workflow slot to make any visual
    // sense — a `currentPage = "workflow"` with `openDocs == []`
    // renders just an empty Item with no toolbar, no palette, no
    // canvas. The nav callback below opens a new-draft on entry to
    // the editor page so the chrome shows up; an unedited draft
    // doesn't persist to disk so leaving it open after the tour is
    // free.
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
                body: "Two brand palettes ship with wflow. Tap one to try it on — the rest of this tour will reskin live. You can swap any time from Settings.",
                paletteChooser: true
            },
            {
                title: "The nav pill",
                body: "The main areas live here — Library, the editor, Record, Settings. Click a tab to switch.",
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
                body: "Hit Debug instead of Run and the engine pauses between every step — Step advances one action, Continue resumes, Stop bails. Inner steps inside a Repeat each get their own dot, so you can see the loop iterate."
            },
            {
                title: "Selection + grouping",
                body: "Shift- or Ctrl-click cards to multi-select; shift- or ctrl-drag empty canvas to lasso. Alt-drag to draw a coloured group rectangle behind cards — purely visual, the engine ignores them.",
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
        // Hydrate AuthController from the persisted snapshot in
        // state.toml. Paints the cached profile immediately and kicks
        // off a /api/v0/me round-trip in the background to verify the
        // token's still live; expired tokens flip back to signed_out
        // automatically.
        Theme._auth.restore()
        // Auto-fire the tour on any launch where the current tour
        // version hasn't been marked seen. Bumping the key (intro_tour
        // → intro_tour_v2 → intro_tour_v3) replays the tour once for returning users
        // when major editor features land. The is_first_run flag is no
        // longer gating this — it's only ever true on the very first
        // launch, which would otherwise pin returning users to the
        // first version they happened to see.
        if (!introState.tutorial_seen("intro_tour_v3")) {
            // Defer two ticks so the chrome's first page transition
            // settles before the coach overlay reads target rects —
            // anchors aren't valid on the very first frame after
            // boot.
            Qt.callLater(() => Qt.callLater(tutorial.start))
        }
        // Pending wflow://import?source=... URL from a browser handoff?
        // Fire the import once the GUI is up. take_pending_deeplink
        // clears the env var so a second poll wouldn't re-import.
        Qt.callLater(() => {
            const url = deeplinkPipe.take_pending_deeplink()
            if (url && url.length > 0) {
                _resolveDeeplink(url)
            }
        })
    }
}
