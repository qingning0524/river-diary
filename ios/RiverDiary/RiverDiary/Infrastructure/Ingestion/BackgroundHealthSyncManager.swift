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

    }

    func schedule() {
        guard hasLocalLibrary else { cancel(); return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Self.nextScheduledRun()
        try? BGTaskScheduler.shared.submit(request)
    }

    func cancel() { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier) }

    /// 本地优先后，后台健康同步只要求本机资料存在；账号不是前提。
    private var hasLocalLibrary: Bool {
        RiverLocalDatabase.databaseFileExists()
    }

    func sync() async {
        guard hasLocalLibrary, HKHealthStore.isHealthDataAvailable() else { return }

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
            healthStore.onHealthSnapshotChanged = { nights, exerciseDays, intervals, workouts, stateOfMind in
                Task {
                    guard self.hasLocalLibrary else { continuation.resume(); return }
                    nodeStore.recordHealthSnapshot(
                        nights: nights,
                        exerciseDays: exerciseDays,
                        intervals: intervals,
                        workouts: workouts,
                        stateOfMind: stateOfMind
                    )
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
        // BGTaskScheduler 要求在 didFinishLaunching 返回前完成注册。
        BackgroundHealthSyncManager.shared.register()
        return true
    }
}
