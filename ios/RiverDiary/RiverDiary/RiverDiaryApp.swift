import Combine
import SwiftUI

@main
struct RiverDiaryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DiaryStore()
    @StateObject private var health = HealthKitStore()
    @StateObject private var riverNode: RiverNodeStore
    @Environment(\.scenePhase) private var scenePhase
    private let syncTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    init() {
        let store = DiaryStore()
        let riverNode = RiverNodeStore()
        store.onScoreChanged = { entry, score in
            riverNode.recordMoodCorrection(dayKey: entry.date, score: score)
        }
        store.onScoreReset = { dayKey in riverNode.recordMoodReset(dayKey: dayKey) }
        riverNode.onMoodScoresChanged = { scores, resetDays in
            store.applySyncedMoodState(scores: scores, resetDays: resetDays)
        }
        let moodState = riverNode.currentMoodState()
        store.applySyncedMoodState(scores: moodState.scores, resetDays: moodState.resets)
        riverNode.migrateLegacyMoodScores(store.localMoodScoresByDate)
        let healthStore = HealthKitStore()
        healthStore.onHealthSnapshotChanged = { nights, exerciseDays in
            await riverNode.recordHealthSnapshot(nights: nights, exerciseDays: exerciseDays)
        }
        _store = StateObject(wrappedValue: store)
        _riverNode = StateObject(wrappedValue: riverNode)
        _health = StateObject(wrappedValue: healthStore)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(health)
                .environmentObject(riverNode)
                .environmentObject(store.drive)
                .tint(.indigo)
                .onAppear { riverNode.restoreLANReplicationPreference(using: store.drive) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                    Task {
                        await store.refreshFromICloud()
                        riverNode.synchronize(using: store.drive, localMoodScores: store.localMoodScoresByDate)
                        riverNode.restoreLANReplicationPreference(using: store.drive)
                    }
                    if health.isAuthorized {
                        health.loadHealth()
                    }
                    } else if phase == .background {
                        riverNode.stopLANReplication()
                        BackgroundHealthSyncManager.shared.schedule()
                    }
                }
                .onReceive(syncTimer) { _ in
                    guard scenePhase == .active else { return }
                    Task {
                        await store.refreshFromICloud()
                        riverNode.synchronize(using: store.drive, localMoodScores: store.localMoodScoresByDate)
                    }
                }
        }
    }
}
