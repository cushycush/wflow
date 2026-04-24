use cxx_qt_build::{CxxQtBuilder, QmlFile, QmlModule};

fn main() {
    CxxQtBuilder::new_qml_module(
        QmlModule::new("Wflow").qml_files([
            // Singletons
            QmlFile::from("qml/Theme.qml").singleton(true),
            QmlFile::from("qml/VisualStyle.qml").singleton(true),
            QmlFile::from("qml/LibraryLayout.qml").singleton(true),
            // Root
            QmlFile::from("qml/Main.qml"),
            // Shared components
            QmlFile::from("qml/components/Sidebar.qml"),
            QmlFile::from("qml/components/SidebarWorkflow.qml"),
            QmlFile::from("qml/components/TopBar.qml"),
            QmlFile::from("qml/components/IconButton.qml"),
            QmlFile::from("qml/components/CategoryChip.qml"),
            QmlFile::from("qml/components/CategoryIcon.qml"),
            QmlFile::from("qml/components/ActionRow.qml"),
            QmlFile::from("qml/components/EmptyState.qml"),
            // Library (user-switchable layouts)
            QmlFile::from("qml/components/library/LibraryLayoutSwitcher.qml"),
            QmlFile::from("qml/components/library/LibraryGrid.qml"),
            QmlFile::from("qml/components/library/LibraryList.qml"),
            // Workflow editor — Split is the only locked layout.
            // Stack / Timeline / Grouped / Cards are archived under
            // qml/components/workflow/_archive (excluded from the build).
            QmlFile::from("qml/components/workflow/SplitInspector.qml"),
            QmlFile::from("qml/components/workflow/OptionNumberRow.qml"),
            // Record
            QmlFile::from("qml/components/record/AmbientRec.qml"),
            // Explore
            QmlFile::from("qml/components/explore/ExploreSearch.qml"),
            QmlFile::from("qml/components/explore/ExploreHero.qml"),
            QmlFile::from("qml/components/explore/CategoryPills.qml"),
            QmlFile::from("qml/components/explore/CommunityCard.qml"),
            QmlFile::from("qml/components/explore/ExploreDetail.qml"),
            // Chrome
            QmlFile::from("qml/components/chrome/ChromeFloating.qml"),
            // Pages
            QmlFile::from("qml/pages/LibraryPage.qml"),
            QmlFile::from("qml/pages/ExplorePage.qml"),
            QmlFile::from("qml/pages/WorkflowPage.qml"),
            QmlFile::from("qml/pages/RecordPage.qml"),
        ]),
    )
    .file("src/bridge/library.rs")
    .file("src/bridge/workflow.rs")
    .file("src/bridge/recorder.rs")
    .qt_module("Quick")
    .qt_module("QuickControls2")
    .build();
}
