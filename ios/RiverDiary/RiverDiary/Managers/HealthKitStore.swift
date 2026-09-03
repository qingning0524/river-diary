import Foundation
import HealthKit
import SwiftUI

struct SleepNight: Identifiable, Hashable {
    let date: Date
    var core: TimeInterval
    var deep: TimeInterval
    var rem: TimeInterval
    var awake: TimeInterval

    var id: Date { date }
    var total: TimeInterval { core + deep + rem }
    var totalHours: Double { total / 3600 }
}

struct ExerciseDay: Identifiable, Hashable {
    let date: Date
    var steps: Double
    var distanceKilometers: Double
    var activeEnergyKilocalories: Double

    var id: Date { date }
}

@MainActor
final class HealthKitStore: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var isLoading = false
    @Published private(set) var nights: [SleepNight] = []
    @Published private(set) var exerciseDays: [ExerciseDay] = []
    @Published private(set) var errorMessage: String?

    var onHealthSnapshotChanged: (([SleepNight], [ExerciseDay]) async -> Void)?

    private let healthStore = HKHealthStore()
    private let connectionKey = "has-connected-healthkit"
    private var pendingLoadCount = 0

    init() {
        if UserDefaults.standard.bool(forKey: connectionKey) {
            isAuthorized = true
            loadHealth()
        }
    }

    var latestNight: SleepNight? { nights.first }
    var averageSleepHours: Double? {
        guard !nights.isEmpty else { return nil }
        return nights.map(\.totalHours).reduce(0, +) / Double(nights.count)
    }

    var latestExerciseDay: ExerciseDay? { exerciseDays.first }
    var averageSteps: Double? {
        guard !exerciseDays.isEmpty else { return nil }
        return exerciseDays.map(\.steps).reduce(0, +) / Double(exerciseDays.count)
    }

    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "此设备不支持 HealthKit"
            return
        }

        let readTypes: Set<HKObjectType> = [
            HKCategoryType(.sleepAnalysis),
            HKQuantityType(.stepCount),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.activeEnergyBurned)
        ]

        isLoading = true
        errorMessage = nil
        healthStore.requestAuthorization(toShare: nil, read: readTypes) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                self.isAuthorized = success
                UserDefaults.standard.set(success, forKey: self.connectionKey)
                self.isLoading = false
                self.errorMessage = error?.localizedDescription
                if success {
                    self.loadHealth()
                }
            }
        }
    }

    func loadHealth() {
        pendingLoadCount = 2
        loadSleep()
        loadExercise()
    }

    func loadSleep() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        isLoading = true
        let sleepType = HKCategoryType(.sleepAnalysis)
        let calendar = Calendar.current
        guard let startDate = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: .now)) else { return }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: 800, sortDescriptors: [sortDescriptor]) { _, samples, error in
            let nights = Self.aggregate(samples: samples)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.nights = nights
                self.isLoading = false
                if let error {
                    self.errorMessage = error.localizedDescription
                }
                await self.notifySnapshotChanged()
            }
            }
        healthStore.execute(query)
    }

    func loadExercise() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        isLoading = true

        let quantityTypes: [(HKQuantityType, (HKQuantity) -> Double)] = [
            (HKQuantityType(.stepCount), { $0.doubleValue(for: .count()) }),
            (HKQuantityType(.distanceWalkingRunning), { $0.doubleValue(for: .meterUnit(with: .kilo)) }),
            (HKQuantityType(.activeEnergyBurned), { $0.doubleValue(for: .kilocalorie()) })
        ]

        Task { [weak self] in
            var collected: [HKQuantityType: [Date: Double]] = [:]
            var queryError: Error?

            for (type, valueReader) in quantityTypes {
                do {
                    collected[type] = try await Self.dailyQuantityTotals(
                        type: type,
                        days: 8,
                        valueReader: valueReader,
                        healthStore: self?.healthStore ?? HKHealthStore()
                    )
                } catch {
                    queryError = error
                }
            }

            let days = Self.aggregateExercise(collected: collected)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.exerciseDays = days
                if let queryError {
                    self.errorMessage = queryError.localizedDescription
                }
                Task { await self.notifySnapshotChanged() }
            }
        }
    }

    private func notifySnapshotChanged() async {
        if pendingLoadCount > 0 {
            pendingLoadCount -= 1
            if pendingLoadCount > 0 { return }
        }
        await onHealthSnapshotChanged?(nights, exerciseDays)
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private nonisolated static func dailyQuantityTotals(
        type: HKQuantityType,
        days: Int,
        valueReader: @escaping (HKQuantity) -> Double,
        healthStore: HKHealthStore
    ) async throws -> [Date: Double] {
        let calendar = Calendar.current
        guard let startDate = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: .now)) else {
            return [:]
        }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: calendar.startOfDay(for: .now),
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, statisticsCollection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                var totals: [Date: Double] = [:]
                statisticsCollection?.enumerateStatistics(from: startDate, to: .now) { statistics, _ in
                    if let sum = statistics.sumQuantity() {
                        totals[calendar.startOfDay(for: statistics.startDate)] = valueReader(sum)
                    }
                }
                continuation.resume(returning: totals)
            }
            healthStore.execute(query)
        }
    }

    private nonisolated static func aggregateExercise(collected: [HKQuantityType: [Date: Double]]) -> [ExerciseDay] {
        var dates = Set<Date>()
        for totals in collected.values {
            dates.formUnion(totals.keys)
        }

        return dates.map { date in
            ExerciseDay(
                date: date,
                steps: collected[HKQuantityType(.stepCount)]?[date] ?? 0,
                distanceKilometers: collected[HKQuantityType(.distanceWalkingRunning)]?[date] ?? 0,
                activeEnergyKilocalories: collected[HKQuantityType(.activeEnergyBurned)]?[date] ?? 0
            )
        }
        .sorted { $0.date > $1.date }
    }

    private nonisolated static func aggregate(samples: [HKSample]?) -> [SleepNight] {
        let calendar = Calendar.current
        var nights: [Date: SleepNight] = [:]

        for sample in samples ?? [] {
            guard let categorySample = sample as? HKCategorySample else { continue }
            let state = HKCategoryValueSleepAnalysis(rawValue: categorySample.value)
            let day = calendar.startOfDay(for: categorySample.endDate)
            var night = nights[day] ?? SleepNight(date: day, core: 0, deep: 0, rem: 0, awake: 0)
            let duration = categorySample.endDate.timeIntervalSince(categorySample.startDate)

            switch state {
            case .asleepCore: night.core += duration
            case .asleepDeep: night.deep += duration
            case .asleepREM: night.rem += duration
            case .some(.awake): night.awake += duration
            default: break
            }
            nights[day] = night
        }

        return nights.values.sorted { $0.date > $1.date }
    }
}
