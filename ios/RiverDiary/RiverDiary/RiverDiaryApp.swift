import SwiftUI

@main
struct RiverDiaryApp: App {
    @StateObject private var store = DiaryStore()
    @StateObject private var health = HealthKitStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = DiaryStore()
        let healthStore = HealthKitStore()
        healthStore.onHealthSnapshotChanged = { nights, exerciseDays in
            await store.saveHealthSnapshot(
                sleepNights: nights,
                exerciseDays: exerciseDays
            )
        }
        _store = StateObject(wrappedValue: store)
        _health = StateObject(wrappedValue: healthStore)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(health)
                .environmentObject(store.drive)
                .tint(.indigo)
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active, health.isAuthorized else { return }
                    health.loadHealth()
                    Task {
                        await store.refreshFromICloud()
                    }
                }
        }
    }
}
