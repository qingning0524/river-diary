import BackgroundTasks
import Foundation
import HealthKit
import RiverDiaryCore
import UIKit

@MainActor
final class BackgroundHealthSyncManager {
    static let shared = BackgroundHealthSyncManager()
    static let taskIdentifier = "local.riverdiary.app.health-sync"

    private var activeHealthStore: HealthKitStore?
    private var activeNodeStore: RiverNodeStore?

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }

            let syncTask = Task { [weak self] in
                await self?.sync()
                task.setTaskCompleted(success: true)
            }

            task.expirationHandler = {
                syncTask.cancel()
                task.setTaskCompleted(success: false)
            }
        }

        schedule()
    }

    func schedule() {
        guard hasSignedInAccount else { cancel(); return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Self.nextScheduledRun()
        try? BGTaskScheduler.shared.submit(request)
    }

    func cancel() { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier) }

    private var hasSignedInAccount: Bool {
        RiverAccountSessionStore(platform: .ios, deviceName: "Background health sync").isSignedIn
    }

    func sync() async {
        guard hasSignedInAccount, HKHealthStore.isHealthDataAvailable() else { return }

        let healthStore = HealthKitStore(loadOnInit: false)
        guard healthStore.isAuthorized else { return }
        let nodeStore = RiverNodeStore()
        let diaryStore = DiaryStore()
        let driveStore = ICloudDriveStore()
        activeHealthStore = healthStore
        activeNodeStore = nodeStore
        defer {
            activeHealthStore = nil
            activeNodeStore = nil
        }

        await withCheckedContinuation { continuation in
            healthStore.onHealthSnapshotChanged = { nights, exerciseDays, intervals in
                Task {
                    guard self.hasSignedInAccount else { continuation.resume(); return }
                    nodeStore.recordHealthSnapshot(nights: nights, exerciseDays: exerciseDays, intervals: intervals)
                    nodeStore.synchronize(using: driveStore, localMoodScores: diaryStore.localMoodScoresByDate)
                    continuation.resume()
                }
            }
            healthStore.loadHealth()
        }

        schedule()
    }

    private static func nextScheduledRun(from date: Date = .now) -> Date? {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = 22
        components.minute = 0

        guard let todayRun = calendar.date(from: components) else { return nil }
        return todayRun > date ? todayRun : calendar.date(byAdding: .day, value: 1, to: todayRun)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Task { @MainActor in
            BackgroundHealthSyncManager.shared.register()
        }
        return true
    }
}
