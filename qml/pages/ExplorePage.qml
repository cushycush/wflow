import QtQuick
import QtQuick.Controls
import Wflow

// Community catalog. Browse and import workflows submitted by other users.
// Read-pane by design — submission, discussion, profiles, ratings all live on
// the web. The app only consumes the catalog.
Item {
    id: root
    signal openWorkflow(string id)      // emitted after import to route to the editor

    property string selectedCategory: "All"
    property var selectedWorkflow: null

    function selectWorkflow(id) {
        const wf = root.communityWorkflows.find(w => w.id === id)
        if (wf) root.selectedWorkflow = wf
    }

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

    readonly property var featured: communityWorkflows[0]
    readonly property var trending: communityWorkflows.filter(w => w.trending)
    readonly property var newSubmissions: communityWorkflows.filter(w => w.newSubmission)
    readonly property var filtered: (
        selectedCategory === "All"
            ? communityWorkflows
            : communityWorkflows.filter(w => w.category === selectedCategory)
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

                ExploreHero {
                    x: 24
                    width: page.width - 48
                    wf: root.featured
                    onActivated: (id) => root.selectWorkflow(id)
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
                        height: 212
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
                                    cardH: 200
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
                        height: 212
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
                                    cardH: 200
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

                    // Auto-column grid
                    Item {
                        id: grid
                        width: parent.width
                        readonly property int cols: Math.max(2, Math.floor(width / 300))
                        readonly property real gap: 12
                        readonly property real cardW: (width - gap * (cols - 1)) / cols
                        readonly property real cardH: 200
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
        open: root.selectedWorkflow !== null
        onClosed: root.selectedWorkflow = null
        onImported: (id) => {
            // TODO: actually import via bridge; for now route to editor.
            root.selectedWorkflow = null
            root.openWorkflow(id)
        }
        onDryRunRequested: (id) => {
            // TODO: dry-run walk-through; mocked.
        }
    }
}
