import QtQuick
import QtQuick.Controls
import Wflow

// Community catalog. Browse and import workflows submitted by other users.
// Read-pane by design. Submission, discussion, profiles, ratings all live on
// the web; the app only consumes the catalog.
//
// Talks to wflows.com over the v0 JSON API (see ExploreController). The
// mock workflow list at the bottom of this file is the offline / pre-
// network fallback; once /api/v0/featured + /api/v0/browse return data
// the live results take over via _liveWorkflows.
Item {
    id: root
    signal openWorkflow(string id)      // emitted after import to route to the editor

    property string selectedCategory: "All"
    property var selectedWorkflow: null
    // Detail JSON for the currently-selected live workflow, populated
    // by ExploreController.fetch_workflow_detail. Carries the parsed
    // step list, install / comment / remix counts, and timestamps.
    // Cleared when the drawer closes or a different card opens so the
    // drawer never paints the previous workflow's data over a fresh
    // selection.
    property var selectedDetail: null
    property bool detailLoading: false

    // The bridge controller. Single instance per page — the chrome's
    // pending-deeplink handoff (see Main.qml) uses its own instance,
    // which is fine because both call into the same store.
    ExploreController {
        id: catalog

        // Wire imports straight into the page's openWorkflow signal so
        // the user lands in the editor as soon as the .kdl is on disk.
        onImport_succeeded: (id) => {
            root.selectedWorkflow = null
            root.selectedDetail = null
            root.openWorkflow(id)
        }
        onImport_failed: (reason) => {
            console.warn("import failed:", reason)
            // Surface in the detail drawer too — the user already
            // clicked Install and is waiting for feedback.
            root._lastImportError = reason
            root.detailLoading = false
        }
        onWorkflow_detail_ready: (detailJson) => {
            try {
                const detail = JSON.parse(detailJson)
                // Confirm the response still matches what the user
                // currently has open. If they jumped between two
                // cards quickly, the in-flight fetch lands after the
                // newer fetch and would paint the wrong workflow.
                const wf = root.selectedWorkflow
                if (wf && wf.handle === detail.handle && wf.slug === detail.slug) {
                    root.selectedDetail = detail
                }
            } catch (e) {
                console.warn("detail parse failed:", e)
            }
            root.detailLoading = false
        }
    }
    property string _lastImportError: ""

    Component.onCompleted: {
        catalog.fetch_featured()
        catalog.fetch_browse("", "", "", "", 0, 24)
    }

    function selectWorkflow(id) {
        const wf = (root._liveWorkflows.length > 0
            ? root._liveWorkflows
            : root.communityWorkflows).find(w => w.id === id)
        if (!wf) return
        root.selectedWorkflow = wf
        // Drop any cached detail from the previous card so the drawer
        // shows a loading state instead of stale data while the new
        // fetch resolves.
        root.selectedDetail = null
        root._lastImportError = ""
        if (wf.handle && wf.slug) {
            root.detailLoading = true
            catalog.fetch_workflow_detail(wf.handle, wf.slug)
        } else {
            root.detailLoading = false
        }
    }

    function _openInBrowser(detailUrl) {
        if (!detailUrl) return
        Qt.openUrlExternally(detailUrl)
    }

    // Map a remote /api/v0 row into the shape the existing card / hero /
    // detail components already expect. Done in one place so the UI
    // doesn't sprout `wf.kinds || wf.actionTypes` ladders everywhere.
    function _toCardShape(row) {
        // actionTypes can land as either `[{kind, value}]` (the v0
        // response carries per-step values for the chip trail) or
        // plain `["kind", ...]` strings on older / sparse responses.
        // Normalise both shapes into `[{kind, value}]` so the card
        // can render either tier without a fallback ladder.
        const trail = (row.actionTypes || []).map(a => {
            if (typeof a === "string") return { kind: a, value: "" }
            return { kind: a.kind || "", value: a.value || a.label || a.summary || "" }
        })
        const kinds = trail.map(t => t.kind)
        return {
            // The local UI uses a synthetic id of the form
            // "@author/slug" so subsequent lookups land back on the
            // same row without any lookup table.
            id: "@" + row.handle + "/" + row.slug,
            handle: row.handle,
            slug: row.slug,
            title: row.title,
            subtitle: row.description || "",
            author: row.handle,
            category: "Community",
            kinds: kinds,
            trail: trail,
            imports: row.installCount || 0,
            forks: row.remixCount || 0,
            steps: row.stepCount || kinds.length,
            hasShell: kinds.indexOf("shell") >= 0,
            trending: false,
            newSubmission: false,
            heroPalette: "amber",
            // Pass-throughs the detail drawer / install button need.
            rawUrl: row.rawUrl || "",
            detailUrl: row.detailUrl || "",
            deeplink: row.deeplink || ""
        }
    }

    readonly property var _featuredRows: {
        try {
            const j = JSON.parse(catalog.featured_json)
            return (j.data || []).map(_toCardShape)
        } catch (e) { return [] }
    }
    readonly property var _browseRows: {
        try {
            const j = JSON.parse(catalog.browse_json)
            return (j.data || []).map(_toCardShape)
        } catch (e) { return [] }
    }
    readonly property var _liveWorkflows: _featuredRows.concat(
        // De-dupe browse against featured so a featured workflow doesn't
        // appear twice on the same page.
        _browseRows.filter(b =>
            !_featuredRows.some(f => f.id === b.id))
    )

    // ==== Mock community workflows ====
    // Shape: { id, title, subtitle, author, category, kinds, imports, forks, steps, hasShell, trending, newSubmission }
    property var communityWorkflows: [
        { id: "c1", title: "git-forensics", subtitle: "investigate recent commits across branches with diffs + authors",
          author: "octant", category: "Dev", kinds: ["shell", "type", "notify"],
          imports: 1243, forks: 87, steps: 9, hasShell: true, trending: true,
          heroPalette: "amber" },
        { id: "c2", title: "standup-start", subtitle: "open slack standup, zoom huddle, project notes side by side",
          author: "minimice", category: "Meetings", kinds: ["focus", "key", "shell"],
          imports: 834, forks: 42, steps: 6, hasShell: true, trending: true },
        { id: "c3", title: "screenshot-annotate-share", subtitle: "region grab → annotate → wl-copy + paste to slack",
          author: "plum", category: "Media", kinds: ["shell", "clipboard", "type"],
          imports: 2104, forks: 138, steps: 7, hasShell: true, trending: true },
        { id: "c4", title: "focus-mode-deep", subtitle: "DND on, music start, hide dock, set window layout",
          author: "quietwater", category: "Focus", kinds: ["notify", "shell", "focus"],
          imports: 512, forks: 29, steps: 5, hasShell: true },
        { id: "c5", title: "zoom-join-next-meeting", subtitle: "parse calendar for next event, auto-join zoom",
          author: "clockwise", category: "Meetings", kinds: ["shell", "type", "key"],
          imports: 1502, forks: 64, steps: 4, hasShell: true, trending: true },
        { id: "c6", title: "kubectl-context-switch", subtitle: "swap kubeconfig + namespace with a picker",
          author: "cloudmouse", category: "Dev", kinds: ["shell", "type", "notify"],
          imports: 678, forks: 51, steps: 6, hasShell: true, trending: true },
        { id: "c7", title: "vpn-toggle-work", subtitle: "wg up/down + notify, fail-safe on timeout",
          author: "railtunnel", category: "System", kinds: ["shell", "notify"],
          imports: 445, forks: 18, steps: 3, hasShell: true, newSubmission: true },
        { id: "c8", title: "screenshare-setup", subtitle: "DND on, hide panels, terminal clean, camera active",
          author: "bunkbed", category: "Meetings", kinds: ["notify", "focus", "shell"],
          imports: 320, forks: 14, steps: 7, hasShell: true, newSubmission: true },
        { id: "c9", title: "daily-journal", subtitle: "open editor with date template, save to ~/journal",
          author: "penandink", category: "Writing", kinds: ["shell", "type", "key"],
          imports: 289, forks: 22, steps: 4, hasShell: true, newSubmission: true },
        { id: "c10", title: "tweet-thread-compose", subtitle: "open drafts, paste clipboard template, preview chars",
          author: "fieldguide", category: "Writing", kinds: ["focus", "clipboard", "type"],
          imports: 156, forks: 9, steps: 5, hasShell: false, newSubmission: true, trending: true },
        { id: "c11", title: "podcast-record-prep", subtitle: "close slack, DND, route audio, start local record",
          author: "airwaves", category: "Media", kinds: ["notify", "shell", "focus"],
          imports: 402, forks: 24, steps: 8, hasShell: true },
        { id: "c12", title: "csv-to-sqlite-inspect", subtitle: "drop a csv, get a queryable sqlite + datasette",
          author: "rowmajor", category: "Data", kinds: ["shell", "notify"],
          imports: 691, forks: 51, steps: 5, hasShell: true }
    ]

    // Prefer live data once the bridge has populated featured + browse;
    // fall back to the mock catalog before the network resolves so the
    // page never paints empty.
    readonly property var _activeCatalog: _liveWorkflows.length > 0
        ? _liveWorkflows
        : communityWorkflows

    // Featured today — the first six rows of the v0 /featured response,
    // or the first six community workflows when offline. wflows.com's
    // featured rotation is six picks per week, so the desktop renders
    // the same six in a curated grid up top.
    readonly property var featuredToday: {
        const src = _liveWorkflows.length > 0 ? _featuredRows : communityWorkflows
        return src.slice(0, 6)
    }
    readonly property var trending: _activeCatalog.filter(w => w.trending)
    readonly property var newSubmissions: _activeCatalog.filter(w => w.newSubmission)
    readonly property var filtered: (
        selectedCategory === "All"
            ? _activeCatalog
            : _activeCatalog.filter(w => w.category === selectedCategory)
    )

    Column {
        anchors.fill: parent
        spacing: 0

        TopBar {
            id: tb
            width: parent.width
            title: "Explore"
            subtitle: "community workflows · " + root.communityWorkflows.length + " in catalog"
        }

        ScrollView {
            width: parent.width
            height: parent.height - tb.height
            contentWidth: availableWidth
            clip: true

            Column {
                id: page
                width: parent.width
                spacing: 28
                topPadding: 24
                bottomPadding: 40

                ExploreSearch {
                    x: 24
                    width: page.width - 48
                }

                // Featured today — wflows.com curates six picks a week
                // and the desktop mirrors that. Two-column layout:
                // the explainer body on the left frames what the
                // section is, the six cards sit on the right in a
                // 3×2 grid (or 2×3 when narrow). The section itself
                // sits inside an accent-tinted rectangle with a
                // hairline coral border so it reads as deliberate
                // curation rather than just another row.
                Item {
                    x: 24
                    width: page.width - 48
                    height: featuredSection.implicitHeight

                    Rectangle {
                        id: featuredSection
                        anchors.fill: parent
                        radius: Theme.radiusLg
                        color: Theme.accentDim
                        border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.35)
                        border.width: 1

                        readonly property real innerPad: 28
                        readonly property real colGap: 28
                        readonly property real leftColW: 260
                        readonly property real rightW: width - innerPad * 2 - leftColW - colGap
                        readonly property int rightCols: rightW > 600 ? 3 : 2
                        readonly property real rightGap: 12
                        readonly property real rightCardW:
                            (rightW - rightGap * (rightCols - 1)) / rightCols
                        readonly property real rightCardH: 220
                        readonly property int rightRows:
                            Math.ceil(root.featuredToday.length / rightCols)
                        readonly property real rightGridH:
                            rightRows * rightCardH + Math.max(0, rightRows - 1) * rightGap

                        implicitHeight: innerPad * 2 + Math.max(leftCol.implicitHeight, rightGridH)

                        Column {
                            id: leftCol
                            x: featuredSection.innerPad
                            y: featuredSection.innerPad
                            width: featuredSection.leftColW
                            spacing: 14

                            Row {
                                spacing: 8
                                Rectangle {
                                    width: 6; height: 6; radius: 3
                                    color: Theme.accent
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    text: "FEATURED TODAY"
                                    color: Theme.accent
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontXs
                                    font.weight: Font.Bold
                                    font.letterSpacing: 1.6
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Text {
                                text: "Six workflows, hand-picked"
                                color: Theme.text
                                font.family: Theme.familyDisplay
                                font.pixelSize: Theme.fontXl
                                font.weight: Font.DemiBold
                                font.letterSpacing: -0.3
                                wrapMode: Text.WordWrap
                                width: parent.width
                            }

                            Text {
                                text: "Every week the wflow team picks six community workflows we think you should try. Real recipes from real people — keyboard chords, shell pipelines, window dances — the kinds of things you stumble on in someone's dotfiles and immediately want for yourself."
                                color: Theme.text2
                                font.family: Theme.familyBody
                                font.pixelSize: Theme.fontSm
                                wrapMode: Text.WordWrap
                                width: parent.width
                                lineHeight: 1.5
                            }

                            Row {
                                spacing: 6
                                topPadding: 4
                                Text {
                                    text: "See all featured"
                                    color: Theme.accent
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontSm
                                    font.weight: Font.DemiBold
                                }
                                Text {
                                    text: "→"
                                    color: Theme.accent
                                    font.family: Theme.familyBody
                                    font.pixelSize: Theme.fontSm
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    // Hook into a future filter ("featured")
                                    // once the v0 endpoint exposes the tag;
                                    // for now this is a visual affordance.
                                }
                            }
                        }

                        Item {
                            id: rightGrid
                            x: featuredSection.innerPad + featuredSection.leftColW + featuredSection.colGap
                            y: featuredSection.innerPad
                            width: featuredSection.rightW
                            height: featuredSection.rightGridH

                            Repeater {
                                model: root.featuredToday
                                delegate: CommunityCard {
                                    wf: modelData
                                    x: (index % featuredSection.rightCols)
                                        * (featuredSection.rightCardW + featuredSection.rightGap)
                                    y: Math.floor(index / featuredSection.rightCols)
                                        * (featuredSection.rightCardH + featuredSection.rightGap)
                                    cardW: featuredSection.rightCardW
                                    cardH: featuredSection.rightCardH
                                    onActivated: (id) => root.selectWorkflow(id)
                                }
                            }
                        }
                    }
                }

                // Category pills
                Item {
                    x: 24
                    width: page.width - 48
                    height: 30
                    CategoryPills {
                        selected: root.selectedCategory
                        onSelectionChanged: (cat) => root.selectedCategory = cat
                    }
                }

                // Trending row — hidden when a category filter is active so
                // the browse grid gets full focus.
                Column {
                    x: 24
                    width: page.width - 48
                    spacing: 12
                    visible: root.selectedCategory === "All"
                    height: visible ? implicitHeight : 0

                    Row {
                        spacing: 8
                        Text {
                            text: "Trending this week"
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontMd
                            font.weight: Font.DemiBold
                        }
                        Text {
                            text: root.trending.length + " workflows"
                            color: Theme.text3
                            font.family: Theme.familyMono
                            font.pixelSize: Theme.fontXs
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    ScrollView {
                        width: parent.width
                        height: 232
                        contentHeight: height
                        clip: true
                        ScrollBar.horizontal.policy: ScrollBar.AsNeeded
                        ScrollBar.vertical.policy: ScrollBar.AlwaysOff

                        Row {
                            spacing: 12
                            Repeater {
                                model: root.trending
                                delegate: CommunityCard {
                                    wf: modelData
                                    cardW: 280
                                    cardH: 220
                                    onActivated: (id) => root.selectWorkflow(id)
                                }
                            }
                        }
                    }
                }

                // New submissions row — also hidden under an active filter.
                Column {
                    x: 24
                    width: page.width - 48
                    spacing: 12
                    visible: root.selectedCategory === "All"
                    height: visible ? implicitHeight : 0

                    Row {
                        spacing: 8
                        Text {
                            text: "New"
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontMd
                            font.weight: Font.DemiBold
                        }
                        Text {
                            text: root.newSubmissions.length + " fresh this week"
                            color: Theme.text3
                            font.family: Theme.familyMono
                            font.pixelSize: Theme.fontXs
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    ScrollView {
                        width: parent.width
                        height: 232
                        contentHeight: height
                        clip: true
                        ScrollBar.horizontal.policy: ScrollBar.AsNeeded
                        ScrollBar.vertical.policy: ScrollBar.AlwaysOff

                        Row {
                            spacing: 12
                            Repeater {
                                model: root.newSubmissions
                                delegate: CommunityCard {
                                    wf: modelData
                                    cardW: 280
                                    cardH: 220
                                    onActivated: (id) => root.selectWorkflow(id)
                                }
                            }
                        }
                    }
                }

                // Browse grid — filtered
                Column {
                    x: 24
                    width: page.width - 48
                    spacing: 12

                    Row {
                        spacing: 8
                        Text {
                            text: root.selectedCategory === "All" ? "Browse" : "Browse · " + root.selectedCategory
                            color: Theme.text
                            font.family: Theme.familyBody
                            font.pixelSize: Theme.fontMd
                            font.weight: Font.DemiBold
                        }
                        Text {
                            text: root.filtered.length + " workflows"
                            color: Theme.text3
                            font.family: Theme.familyMono
                            font.pixelSize: Theme.fontXs
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    // Auto-column grid — same proportions as the Library
                    // grid so a workflow on Explore reads at the same
                    // visual cadence as a workflow on Library.
                    Item {
                        id: grid
                        width: parent.width
                        readonly property int cols: Math.max(2, Math.floor(width / 300))
                        readonly property real gap: 12
                        readonly property real cardW: (width - gap * (cols - 1)) / cols
                        readonly property real cardH: 220
                        readonly property int rows: Math.ceil(root.filtered.length / cols)
                        height: rows * cardH + Math.max(0, rows - 1) * gap

                        Repeater {
                            model: root.filtered
                            delegate: CommunityCard {
                                wf: modelData
                                x: (index % grid.cols) * (grid.cardW + grid.gap)
                                y: Math.floor(index / grid.cols) * (grid.cardH + grid.gap)
                                cardW: grid.cardW
                                cardH: grid.cardH
                                onActivated: (id) => root.selectWorkflow(id)
                            }
                        }
                    }
                }
            }
        }
    }

    // ==== Detail drawer ====
    ExploreDetail {
        anchors.fill: parent
        wf: root.selectedWorkflow
        detail: root.selectedDetail
        loading: root.detailLoading
        open: root.selectedWorkflow !== null
        onClosed: {
            root.selectedWorkflow = null
            root.selectedDetail = null
        }
        onImported: (id) => {
            const wf = root.selectedWorkflow
            // Live entries carry handle + slug; fall back to id-based
            // routing for any leftover mock cards (only matters before
            // the network call lands or in offline mode).
            if (wf && wf.handle && wf.slug) {
                root._lastImportError = ""
                catalog.import_workflow(wf.handle, wf.slug)
            } else {
                root.selectedWorkflow = null
                root.openWorkflow(id)
            }
        }
        onDryRunRequested: (id) => {
            // Dry-run walk-through is on the roadmap. For now, kick the
            // user to the workflow's page on wflows.com, where the
            // hosted preview already shows steps + KDL.
            const wf = root.selectedWorkflow
            if (wf && wf.detailUrl) root._openInBrowser(wf.detailUrl)
        }
    }
}
