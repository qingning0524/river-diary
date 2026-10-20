import Combine
import RiverDiaryCore
import SwiftUI
import UIKit

@main
struct RiverDiaryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DiaryStore()
    @StateObject private var health = HealthKitStore()
    @StateObject private var riverNode: RiverNodeStore
    @StateObject private var accountSession: RiverAccountSessionStore
    @StateObject private var themeStore = RiverThemeStore()
    @Environment(\.scenePhase) private var scenePhase
    private let syncTimer = Timer.publish(every: 120, on: .main, in: .common).autoconnect()

    init() {
        let account = RiverAccountSessionStore(platform: .ios, deviceName: UIDevice.current.name)
        _accountSession = StateObject(wrappedValue: account)
        RiverDiaryQAReset.resetLocalStoreIfRequested()
        let store = DiaryStore()
        let riverNode = RiverNodeStore()
        riverNode.locationCollector?.setSessionActive(account.isSignedIn)
        if !account.isSignedIn { riverNode.motionCollector?.stop() }
        store.onScoreChanged = { entry, score in
            riverNode.recordMoodCorrection(dayKey: entry.date, score: score)
        }
        store.onScoreReset = { dayKey in riverNode.recordMoodReset(dayKey: dayKey) }
        store.onLegacyDiarySnapshotLoaded = { [weak riverNode] snapshot in
            riverNode?.importLegacyDiarySnapshot(snapshot)
        }
        riverNode.onMoodScoresChanged = { scores, resetDays in
            store.applySyncedMoodState(scores: scores, resetDays: resetDays)
        }
        let moodState = riverNode.currentMoodState()
        store.applySyncedMoodState(scores: moodState.scores, resetDays: moodState.resets)
        riverNode.migrateLegacyMoodScores(store.localMoodScoresByDate)
        let healthStore = HealthKitStore()
        healthStore.onHealthSnapshotChanged = { nights, exerciseDays, intervals in
            guard account.isSignedIn else { return }
            riverNode.recordHealthSnapshot(nights: nights, exerciseDays: exerciseDays, intervals: intervals)
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
                .environmentObject(accountSession)
                .environmentObject(themeStore)
                .preferredColorScheme(themeStore.preferredColorScheme)
                .task { await accountSession.retryPendingSignOuts() }
                .onAppear {
                    if accountSession.isSignedIn {
                        riverNode.restoreLANReplicationPreference(using: store.drive)
                        riverNode.motionCollector?.start()
                        riverNode.aiStore?.refreshAutomaticSchedule()
                        Task { await riverNode.photoAnalyzer?.refreshRecentPhotos() }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        guard accountSession.isSignedIn else { return }
                        Task {
                            await store.refreshFromICloud()
                            guard accountSession.isSignedIn else { return }
                            riverNode.synchronize(using: store.drive, localMoodScores: store.localMoodScoresByDate)
                            riverNode.restoreLANReplicationPreference(using: store.drive)
                            riverNode.motionCollector?.start()
                            riverNode.aiStore?.refreshAutomaticSchedule()
                            await riverNode.photoAnalyzer?.refreshRecentPhotos()
                        }
                        if health.isAuthorized { health.loadHealth() }
                    } else if phase == .background {
                        riverNode.stopLANReplication()
                        if accountSession.isSignedIn { BackgroundHealthSyncManager.shared.schedule() }
                    }
                }
                .onChange(of: accountSession.isSignedIn) { _, signedIn in
                    if signedIn {
                        riverNode.locationCollector?.setSessionActive(true)
                        Task {
                            await store.refreshFromICloud()
                            guard accountSession.isSignedIn else { return }
                            riverNode.synchronize(using: store.drive, localMoodScores: store.localMoodScoresByDate)
                            riverNode.restoreLANReplicationPreference(using: store.drive)
                            riverNode.motionCollector?.start()
                            riverNode.aiStore?.refreshAutomaticSchedule()
                            await riverNode.photoAnalyzer?.refreshRecentPhotos()
                        }
                    } else {
                        riverNode.stopLANReplication()
                        riverNode.motionCollector?.stop()
                        riverNode.locationCollector?.setSessionActive(false)
                        BackgroundHealthSyncManager.shared.cancel()
                    }
                }
                .onReceive(syncTimer) { _ in
                    guard scenePhase == .active, accountSession.isSignedIn else { return }
                    riverNode.aiStore?.refreshAutomaticSchedule()
                    Task {
                        await store.refreshFromICloud()
                        guard accountSession.isSignedIn else { return }
                        riverNode.synchronize(using: store.drive, localMoodScores: store.localMoodScoresByDate)
                    }
                }
        }
    }
}

private enum RiverDiaryQAReset {
    static func resetLocalStoreIfRequested() {
        let qaBundleID = "studio.riverdiary.ios.qa"
        guard Bundle.main.bundleIdentifier == qaBundleID,
              ProcessInfo.processInfo.arguments.contains("--riverdiary-qa-reset-local-state") else { return }

        UserDefaults.standard.removePersistentDomain(forName: qaBundleID)
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let databaseDirectory = support
            .appendingPathComponent("RiverDiary", isDirectory: true)
            .appendingPathComponent("Database", isDirectory: true)
        try? FileManager.default.removeItem(at: support.appendingPathComponent("RiverDiary/Drafts", isDirectory: true))
        for filename in ["river-node.sqlite", "river-node.sqlite-wal", "river-node.sqlite-shm", "river-node.sqlite-journal"] {
            try? FileManager.default.removeItem(at: databaseDirectory.appendingPathComponent(filename))
        }
    }
}
