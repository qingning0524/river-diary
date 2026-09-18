import SwiftUI

@main
struct RiverDiaryMacApp: App {
    @StateObject private var ingestion = DataIngestionStore()
    @StateObject private var store = DiaryStore()
    @StateObject private var activity = ActivityStore()
    @StateObject private var ai = AIAssistantStore()

    var body: some Scene {
        WindowGroup {
            RiverShellView(store: store, activity: activity, ai: ai, ingestion: ingestion)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))

        MenuBarExtra("River 快记", systemImage: "leaf.fill") {
            QuickCaptureView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
