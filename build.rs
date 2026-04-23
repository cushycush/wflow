use cxx_qt_build::{CxxQtBuilder, QmlFile, QmlModule};

fn main() {
    CxxQtBuilder::new_qml_module(
        QmlModule::new("Wflow").qml_files([
            // Singletons
            QmlFile::from("qml/Theme.qml").singleton(true),
            QmlFile::from("qml/VisualStyle.qml").singleton(true),
            QmlFile::from("qml/LibraryLayout.qml").singleton(true),
            QmlFile::from("qml/WorkflowLayout.qml").singleton(true),
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
            QmlFile::from("qml/components/StyleBadge.qml"),
            // Library layout variants
            QmlFile::from("qml/components/library/GridRich.qml"),
            QmlFile::from("qml/components/library/ListDense.qml"),
            QmlFile::from("qml/components/library/Mosaic.qml"),
            QmlFile::from("qml/components/library/HeroGrid.qml"),
            QmlFile::from("qml/components/library/Timeline.qml"),
            QmlFile::from("qml/components/library/CompactGrid.qml"),
            // Workflow layout variants
            QmlFile::from("qml/components/workflow/StackList.qml"),
            QmlFile::from("qml/components/workflow/HorizontalTimeline.qml"),
            QmlFile::from("qml/components/workflow/SplitInspector.qml"),
            QmlFile::from("qml/components/workflow/GroupedPhases.qml"),
            QmlFile::from("qml/components/workflow/CardDeck.qml"),
            // Record
            QmlFile::from("qml/components/record/AmbientRec.qml"),
            // Chrome
            QmlFile::from("qml/components/chrome/ChromeFloating.qml"),
            // Pages
            QmlFile::from("qml/pages/LibraryPage.qml"),
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
