import QtQuick
import QtQuick.Controls
import Wflow

// "My favorites" — workflows the signed-in user has starred on
// wflows.io. Mirrors ExplorePage's grid + drawer composition but
// without the Featured / Trending / New sections that don't make
// sense for a personal collection. The page is hidden in the nav
// when signed out (see ChromeFloating's pill model).
Item {
    id: root
    signal openWorkflow(string id)

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
                const wf = root.selectedWorkflow
                if (wf && wf.handle === detail.handle && wf.slug === detail.slug) {
                    root.selectedDetail = detail
                }
            } catch (e) {
                console.warn("detail parse failed:", e)
            }
            root.detailLoading = false
        }
        // 401 from /favorites means the token's dead. Hand off to the
        // shared AuthController; SettingsPage flips back to signed_out
        // automatically off Theme._auth.state.
        onAuth_expired: {
            Theme._auth.sign_out()
        }
    }
    property string _lastImportError: ""

    // Refresh on every visibility flip so a user who signs in, lands
    // on Library, then clicks Favorites doesn't see stale data. Cheap
    // — the bridge collapses re-entrant fetches.
    onVisibleChanged: {
        if (visible && Theme._auth.state === "signed_in") {
            catalog.fetch_favorites()
        }
    }
    // Also re-fetch when the auth state flips to signed_in while the
    // page is already visible (rare but possible if the user signed
    // in via a deeplink while the favorites page was the active tab).
    Connections {
        target: Theme._auth
        function onSign_in_succeeded(handle) {
            if (root.visible) {
                catalog.fetch_favorites()
            }
        }
    }

    function selectWorkflow(id) {
        const wf = (root.workflows || []).find(w => w.id === id)
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

    // Map the v0 favorites response (same envelope as /browse) into
    // the card shape every other Explore surface uses. Kept inline
    // rather than shared with ExplorePage so a future divergence in
    // favorites-specific fields (a `favoritedAt` timestamp, say) can
    // land here without rippling through the Explore mapper.
    function _toCardShape(row) {
        const trail = (row.actionTypes || []).map(a => {
            if (typeof a === "string") return { kind: a, value: "" }
            return { kind: a.kind || "", value: a.value || a.label || a.summary || "" }
        })
        const kinds = trail.map(t => t.kind)
        return {
            id: "@" + row.handle + "/" + row.slug,
            handle: row.handle,
            slug: row.slug,
            title: row.title,
            subtitle: row.description || "",
            author: row.handle,
            category: "Favorite",
            kinds: kinds,
            trail: trail,
            imports: row.installCount || 0,
            forks: row.remixCount || 0,
            steps: row.stepCount || kinds.length,
            hasShell: kinds.indexOf("shell") >= 0,
            heroPalette: "amber",
            rawUrl: row.rawUrl || "",
            detailUrl: row.detailUrl || "",
            deeplink: row.deeplink || ""
        }
    }

    readonly property var workflows: {
        try {
            const j = JSON.parse(catalog.favorites_json)
            return (j.data || []).map(_toCardShape)
        } catch (e) { return [] }
    }

    Column {
        anchors.fill: parent
        spacing: 0

        TopBar {
            id: tb
            width: parent.width
            title: "Favorites"
            subtitle: root.workflows.length === 1
                ? "1 workflow starred on wflows.io"
                : root.workflows.length + " workflows starred on wflows.io"
        }

        ScrollView {
            width: parent.width
            height: parent.height - tb.height
            contentWidth: availableWidth
            clip: true

            // Empty state — signed in but nothing favorited yet, or
            // the fetch hasn't resolved on first paint.
            Item {
                anchors.fill: parent
                visible: root.workflows.length === 0
                Column {
                    anchors.centerIn: parent
                    spacing: 12
                    Text {
                        text: catalog.loading ? "Loading favorites…" : "No favorites yet"
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: Theme.text2
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontMd
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: catalog.loading
                            ? ""
                            : "Star a workflow on Explore (or on wflows.io) to find it here."
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: Theme.text3
                        font.family: Theme.familyBody
                        font.pixelSize: Theme.fontSm
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignHCenter
                        width: 360
                        visible: text.length > 0
                    }
                }
            }

            Column {
                id: page
                width: parent.width
                spacing: 24
                topPadding: 24
                bottomPadding: 40
                visible: root.workflows.length > 0

                // Grid — same proportions as Explore's browse grid so
                // a workflow card on Favorites reads at the same
                // cadence as a card on Explore. No filter chips, no
                // sub-sections; this is a personal list.
                Column {
                    x: 24
                    width: page.width - 48
                    spacing: 12

                    Item {
                        id: grid
                        width: parent.width
                        readonly property int cols: Math.max(2, Math.floor(width / 300))
                        readonly property real gap: 12
                        readonly property real cardW: (width - gap * (cols - 1)) / cols
                        readonly property real cardH: 220
                        readonly property int rows: Math.ceil(root.workflows.length / cols)
                        height: rows * cardH + Math.max(0, rows - 1) * gap

                        Repeater {
                            model: root.workflows
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

    // Detail drawer — same component as Explore so the visual
    // language (timeline + chip dots) is consistent across the
    // surfaces a workflow can be opened from.
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
            if (wf && wf.handle && wf.slug) {
                root._lastImportError = ""
                catalog.import_workflow(wf.handle, wf.slug)
            } else {
                root.selectedWorkflow = null
                root.openWorkflow(id)
            }
        }
        onDryRunRequested: (id) => {
            const wf = root.selectedWorkflow
            if (wf && wf.detailUrl) Qt.openUrlExternally(wf.detailUrl)
        }
    }
}
