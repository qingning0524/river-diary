import Combine
import SwiftUI

@main
struct RiverDiaryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DiaryStore()
    @StateObject private var health = HealthKitStore()
    @Environment(\.scenePhase) private var scenePhase
    private let syncTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

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
                    if phase == .active {
                    Task {
                        await store.refreshFromICloud()
                    }
                    if health.isAuthorized {
                        health.loadHealth()
                    }
                    } else if phase == .background {
                        BackgroundHealthSyncManager.shared.schedule()
                    }
                }
                .onReceive(syncTimer) { _ in
                    guard scenePhase == .active else { return }
                    Task {
                        await store.refreshFromICloud()
                    }
                }
        }
    }
}
