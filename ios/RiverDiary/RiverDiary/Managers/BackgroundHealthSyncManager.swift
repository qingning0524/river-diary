import BackgroundTasks
import Foundation
import HealthKit
import UIKit

@MainActor
final class BackgroundHealthSyncManager {
    static let shared = BackgroundHealthSyncManager()
    static let taskIdentifier = "local.riverdiary.app.health-sync"

    private var activeHealthStore: HealthKitStore?
    private var activeDiaryStore: DiaryStore?

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
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Self.nextScheduledRun()
        try? BGTaskScheduler.shared.submit(request)
    }

    func sync() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let healthStore = HealthKitStore()
        let diaryStore = DiaryStore()
        activeHealthStore = healthStore
        activeDiaryStore = diaryStore
        defer {
            activeHealthStore = nil
            activeDiaryStore = nil
        }

        await withCheckedContinuation { continuation in
            healthStore.onHealthSnapshotChanged = { nights, exerciseDays in
                Task {
                    await diaryStore.saveHealthSnapshot(
                        sleepNights: nights,
                        exerciseDays: exerciseDays
                    )
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
