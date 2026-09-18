import SwiftUI

@main
struct RiverDiaryMacApp: App {
    @StateObject private var ingestion = DataIngestionStore()
    @StateObject private var store = DiaryStore()
    @StateObject private var activity = ActivityStore()
    @StateObject private var ai = AIAssistantStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store, activity: activity, ai: ai, ingestion: ingestion)
                .onDisappear {
                    ingestion.stop()
                }
                .frame(minWidth: 1120, minHeight: 720)
        }
        .defaultSize(width: 1420, height: 920)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))

        MenuBarExtra("River Diary 快记", systemImage: "leaf.fill") {
            QuickCaptureView(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
