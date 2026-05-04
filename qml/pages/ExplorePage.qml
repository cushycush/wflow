import QtQuick
import QtQuick.Controls
import Wflow

// Read-pane catalog of community workflows. Submission / discussion /
// ratings live on the web. Live data via ExploreController; mock list
// at the bottom is the offline fallback.
Item {
    id: root
    signal openWorkflow(string id)

    property string selectedCategory: "All"
    property var selectedWorkflow: null
    property var selectedDetail: null
    property bool detailLoading: false

    ExploreController {
        id: catalog

        onImport_succeeded: (id) => {
            root.selectedWorkflow = null
            root.selectedDetail = null
            root.openWorkflow(id)
        }
        onImport_failed: (reason) => {
            console.warn("import failed:", reason)
            root._lastImportError = reason
            root.detailLoading = false
        }
        onWorkflow_detail_ready: (detailJson) => {
            try {
                const detail = JSON.parse(detailJson)
                // Drop late-arriving responses if the user jumped to
                // another card after the fetch went out.
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

    // Maps an /api/v0 row into the local card shape so the UI doesn't
    // sprout `wf.kinds || wf.actionTypes` ladders.
    function _toCardShape(row) {
        // actionTypes can be `[{kind, value}]` or `["kind", ...]`;
        // normalise both into the object form.
        const trail = (row.actionTypes || []).map(a => {
            if (typeof a === "string") return { kind: a, value: "" }
            return { kind: a.kind || "", value: a.value || a.label || a.summary || "" }
        })
        const kinds = trail.map(t => t.kind)
        return {
            // Synthetic id "@handle/slug" so lookups need no extra table.
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
            stars: row.starCount || 0,
            forks: row.remixCount || 0,
            steps: row.stepCount || kinds.length,
            hasShell: kinds.indexOf("shell") >= 0,
            trending: false,
            newSubmission: false,
            heroPalette: "amber",
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
        // De-dupe browse against featured.
        _browseRows.filter(b =>
            !_featuredRows.some(f => f.id === b.id))
    )

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

    readonly property var _activeCatalog: _liveWorkflows.length > 0
        ? _liveWorkflows
        : communityWorkflows

    // Six picks/week, mirrored from the wflows.io rotation.
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
                                text: "Every week the wflow team picks six community workflows we think you should try. Real recipes from real people, keyboard chords, shell pipelines, window dances, the kinds of things you stumble on in someone's dotfiles and immediately want for yourself."
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

                Item {
                    x: 24
                    width: page.width - 48
                    height: 30
                    CategoryPills {
                        selected: root.selectedCategory
                        onSelectionChanged: (cat) => root.selectedCategory = cat
                    }
                }

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

                    // ScrollView's nested Flickable steals vertical
                    // wheel events; interactive:false + a horizontal
                    // WheelHandler keeps vertical bubbling to the page.
                    Flickable {
                        id: trendingFlick
                        width: parent.width
                        height: 232
                        contentWidth: trendingRow.width
                        contentHeight: height
                        flickableDirection: Flickable.HorizontalFlick
                        boundsBehavior: Flickable.StopAtBounds
                        interactive: false
                        clip: true

                        Row {
                            id: trendingRow
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

                        WheelHandler {
                            orientation: Qt.Horizontal
                            onWheel: (wheel) => {
                                trendingFlick.contentX = Math.max(0,
                                    Math.min(
                                        Math.max(0, trendingFlick.contentWidth - trendingFlick.width),
                                        trendingFlick.contentX - wheel.angleDelta.x))
                            }
                        }

                        ScrollBar.horizontal: ScrollBar {
                            policy: ScrollBar.AsNeeded
                        }
                    }
                }

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

                    Flickable {
                        id: newFlick
                        width: parent.width
                        height: 232
                        contentWidth: newRow.width
                        contentHeight: height
                        flickableDirection: Flickable.HorizontalFlick
                        boundsBehavior: Flickable.StopAtBounds
                        interactive: false
                        clip: true

                        Row {
                            id: newRow
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

                        WheelHandler {
                            orientation: Qt.Horizontal
                            onWheel: (wheel) => {
                                newFlick.contentX = Math.max(0,
                                    Math.min(
                                        Math.max(0, newFlick.contentWidth - newFlick.width),
                                        newFlick.contentX - wheel.angleDelta.x))
                            }
                        }

                        ScrollBar.horizontal: ScrollBar {
                            policy: ScrollBar.AsNeeded
                        }
                    }
                }

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
            // Mock cards have no handle/slug; fall through to id routing.
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
            // user to the workflow's page on wflows.io, where the
            // hosted preview already shows steps + KDL.
            const wf = root.selectedWorkflow
            if (wf && wf.detailUrl) root._openInBrowser(wf.detailUrl)
        }
    }
}
