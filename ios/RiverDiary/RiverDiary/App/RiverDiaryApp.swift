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
        let account = RiverAccountSessionStore(platform: .ios, deviceName: UIDevice.current.name, loadPersistedSession: false)
        _accountSession = StateObject(wrappedValue: account)
        RiverDiaryQAReset.resetLocalStoreIfRequested()
        let store = DiaryStore()
        // v5.0 本地优先：首次启动就开本机资料，账号只是后续增强。
        let riverNode = RiverNodeStore(opensImmediately: true)
        account.localProfileOwnerProvider = { riverNode.localProfileOwner }
        account.localProfileOwnerWriter = { try riverNode.setLocalProfileOwner($0) }
        account.localProfileOwnerClearer = {
            guard let database = riverNode.database else { return }
            try database.clearLocalProfileOwner()
        }
        riverNode.locationCollector?.setSessionActive(true)
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
        healthStore.onHealthSnapshotChanged = { nights, exerciseDays, intervals, workouts, stateOfMind in
            guard riverNode.database != nil else { return }
            riverNode.recordHealthSnapshot(
                nights: nights,
                exerciseDays: exerciseDays,
                intervals: intervals,
                workouts: workouts,
                stateOfMind: stateOfMind
            )
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
                .task {
                    // 本地优先：先显示本机界面，再按需加载账号 Keychain。
                    accountSession.loadPersistedSessionIfNeeded()
                    accountSession.seedLocalProfileOwnerFromKeychain()
                    await accountSession.retryPendingSignOuts()
                    await accountSession.enforceLocalProfileOwner()
                }
                .onAppear {
                    riverNode.openIfNeeded()
                    riverNode.restoreLANReplicationPreference(using: store.drive)
                    riverNode.motionCollector?.start()
                    riverNode.aiStore?.refreshAutomaticSchedule()
                    Task { await riverNode.photoAnalyzer?.refreshRecentPhotos() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task {
                            await store.refreshFromICloud()
                            guard riverNode.database != nil else { return }
                            riverNode.synchronize(using: store.drive, localMoodScores: store.localMoodScoresByDate)
                            riverNode.restoreLANReplicationPreference(using: store.drive)
                            riverNode.motionCollector?.start()
                            riverNode.aiStore?.refreshAutomaticSchedule()
                            await riverNode.photoAnalyzer?.refreshRecentPhotos()
                        }
                        if health.isAuthorized { health.loadHealth() }
                    } else if phase == .background {
                        riverNode.stopLANReplication()
                        if riverNode.database != nil { BackgroundHealthSyncManager.shared.schedule() }
                    }
                }
                .onChange(of: accountSession.isSignedIn) { _, signedIn in
                    if signedIn {
                        // 本地优先后库通常已打开；这里幂等确认，并让账号能力接上。
                        riverNode.openIfNeeded()
                        Task { await accountSession.enforceLocalProfileOwner() }
                    } else {
                        // 退出登录只停账号能力；本机日记、采集、同步与备份继续。
                        riverNode.openIfNeeded()
                    }
                }
                .onReceive(syncTimer) { _ in
                    guard scenePhase == .active, riverNode.database != nil else { return }
                    riverNode.aiStore?.refreshAutomaticSchedule()
                    Task {
                        await store.refreshFromICloud()
                        guard riverNode.database != nil else { return }
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
