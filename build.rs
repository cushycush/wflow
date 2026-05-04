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
            QmlFile::from("qml/components/WorkflowIcon.qml"),
            QmlFile::from("qml/components/ActionRow.qml"),
            QmlFile::from("qml/components/EmptyState.qml"),
            QmlFile::from("qml/components/FocusRing.qml"),
            QmlFile::from("qml/components/TutorialOverlay.qml"),
            QmlFile::from("qml/components/TutorialCoach.qml"),
            QmlFile::from("qml/components/IntroTutorial.qml"),
            QmlFile::from("qml/components/PrimaryButton.qml"),
            QmlFile::from("qml/components/SecondaryButton.qml"),
            QmlFile::from("qml/components/SegmentedControl.qml"),
            QmlFile::from("qml/components/WfMenu.qml"),
            QmlFile::from("qml/components/WfMenuItem.qml"),
            QmlFile::from("qml/components/WfConfirmDialog.qml"),
            QmlFile::from("qml/components/DeeplinkConfirmDialog.qml"),
            QmlFile::from("qml/components/ChordCaptureDialog.qml"),
            QmlFile::from("qml/components/GradientPill.qml"),
            QmlFile::from("qml/components/Avatar.qml"),
            QmlFile::from("qml/components/MiniStep.qml"),
            QmlFile::from("qml/components/StepChipTrail.qml"),
            QmlFile::from("qml/components/DotGrid.qml"),
            // Library (user-switchable layouts)
            QmlFile::from("qml/components/library/LibraryLayoutSwitcher.qml"),
            QmlFile::from("qml/components/library/LibraryGrid.qml"),
            QmlFile::from("qml/components/library/LibraryList.qml"),
            // Workflow editor — single canvas-centric layout: a thin
            // step rail on the left, the node-graph canvas in the
            // middle, and a slide-in inspector on the right when a
            // step is selected. SplitInspector lives on under
            // qml/components/workflow/_archive (excluded from build)
            // alongside the older Stack / Timeline / Grouped / Cards
            // layouts that were tried during exploration.
            QmlFile::from("qml/components/workflow/StepListRail.qml"),
            QmlFile::from("qml/components/workflow/StepInspectorPanel.qml"),
            QmlFile::from("qml/components/workflow/StepPalette.qml"),
            QmlFile::from("qml/components/workflow/WorkflowCanvas.qml"),
            QmlFile::from("qml/components/workflow/OptionNumberRow.qml"),
            QmlFile::from("qml/components/workflow/NewWorkflowDialog.qml"),
            // Record
            QmlFile::from("qml/components/record/AmbientRec.qml"),
            // Explore
            QmlFile::from("qml/components/explore/ExploreSearch.qml"),
            QmlFile::from("qml/components/explore/CategoryPills.qml"),
            QmlFile::from("qml/components/explore/CommunityCard.qml"),
            QmlFile::from("qml/components/explore/ExploreDetail.qml"),
            // Chrome
            QmlFile::from("qml/components/chrome/ChromeFloating.qml"),
            // Pages
            QmlFile::from("qml/pages/LibraryPage.qml"),
            QmlFile::from("qml/pages/ExplorePage.qml"),
            QmlFile::from("qml/pages/FavoritesPage.qml"),
            QmlFile::from("qml/pages/TriggersPage.qml"),
            QmlFile::from("qml/pages/WorkflowPage.qml"),
            QmlFile::from("qml/pages/RecordPage.qml"),
            QmlFile::from("qml/pages/SettingsPage.qml"),
        ]),
    )
    .file("src/bridge/auth.rs")
    .file("src/bridge/deeplink_inbox.rs")
    .file("src/bridge/explore.rs")
    .file("src/bridge/library.rs")
    .file("src/bridge/state.rs")
    .file("src/bridge/workflow.rs")
    .file("src/bridge/recorder.rs")
    .qt_module("Quick")
    .qt_module("QuickControls2")
    .build();
}
