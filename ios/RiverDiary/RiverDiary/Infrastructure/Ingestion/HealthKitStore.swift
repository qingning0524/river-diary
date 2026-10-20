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

struct ExerciseInterval: Identifiable, Hashable {
    let start: Date
    let end: Date
    var steps: Double?
    var distanceKilometers: Double?
    var activeEnergyKilocalories: Double?

    var id: Date { start }
}

@MainActor
final class HealthKitStore: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var isLoading = false
    @Published private(set) var nights: [SleepNight] = []
    @Published private(set) var exerciseDays: [ExerciseDay] = []
    @Published private(set) var exerciseIntervals: [ExerciseInterval] = []
    @Published private(set) var errorMessage: String?

    var onHealthSnapshotChanged: (([SleepNight], [ExerciseDay], [ExerciseInterval]) async -> Void)?

    private let healthStore = HKHealthStore()
    private let connectionKey = "has-connected-healthkit"
    private var refreshBatch = HealthRefreshBatch()

    init(loadOnInit: Bool = true) {
        if UserDefaults.standard.bool(forKey: connectionKey) {
            isAuthorized = true
            if loadOnInit { loadHealth() }
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
        guard HKHealthStore.isHealthDataAvailable(), let generation = refreshBatch.begin() else { return }
        isLoading = true
        errorMessage = nil
        loadSleep(generation: generation)
        loadExercise(generation: generation)
    }

    private func loadSleep(generation: UUID) {
        let sleepType = HKCategoryType(.sleepAnalysis)
        let calendar = Calendar.current
        guard let startDate = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: .now)) else {
            Task { await notifySnapshotChanged(part: .sleep, generation: generation) }
            return
        }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: 800, sortDescriptors: [sortDescriptor]) { [weak self] _, samples, error in
            let nights = HealthKitStore.aggregate(samples: samples)
            Task { @MainActor [weak self] in
                guard let self, self.refreshBatch.accepts(generation) else { return }
                self.nights = nights
                if let error {
                    self.errorMessage = error.localizedDescription
                }
                await self.notifySnapshotChanged(part: .sleep, generation: generation)
            }
            }
        healthStore.execute(query)
    }

    private func loadExercise(generation: UUID) {

        let quantityTypes: [(HKQuantityType, (HKQuantity) -> Double)] = [
            (HKQuantityType(.stepCount), { $0.doubleValue(for: .count()) }),
            (HKQuantityType(.distanceWalkingRunning), { $0.doubleValue(for: .meterUnit(with: .kilo)) }),
            (HKQuantityType(.activeEnergyBurned), { $0.doubleValue(for: .kilocalorie()) })
        ]

        Task { [weak self] in
            var collected: [HKQuantityType: [Date: Double]] = [:]
            var intervalTotals: [HKQuantityType: [Date: Double]] = [:]
            var queryError: Error?

            for (type, valueReader) in quantityTypes {
                do {
                    collected[type] = try await Self.quantityTotals(
                        type: type,
                        days: 8,
                        interval: DateComponents(day: 1),
                        valueReader: valueReader,
                        healthStore: self?.healthStore ?? HKHealthStore()
                    )
                    intervalTotals[type] = try await Self.quantityTotals(
                        type: type,
                        days: 2,
                        interval: DateComponents(minute: 15),
                        valueReader: valueReader,
                        healthStore: self?.healthStore ?? HKHealthStore()
                    )
                } catch {
                    queryError = error
                }
            }

            let days = Self.aggregateExercise(collected: collected)
            let intervals = Self.aggregateExerciseIntervals(collected: intervalTotals)
            await MainActor.run { [weak self] in
                guard let self, self.refreshBatch.accepts(generation) else { return }
                self.exerciseDays = days
                self.exerciseIntervals = intervals
                if let queryError {
                    self.errorMessage = queryError.localizedDescription
                }
                Task { await self.notifySnapshotChanged(part: .exercise, generation: generation) }
            }
        }
    }

    private func notifySnapshotChanged(part: HealthRefreshBatch.Part, generation: UUID) async {
        guard refreshBatch.finish(part, generation: generation) else { return }
        isLoading = false
        await onHealthSnapshotChanged?(nights, exerciseDays, exerciseIntervals)
    }

    private nonisolated static func quantityTotals(
        type: HKQuantityType,
        days: Int,
        interval: DateComponents,
        valueReader: @escaping (HKQuantity) -> Double,
        healthStore: HKHealthStore
    ) async throws -> [Date: Double] {
        let calendar = Calendar.current
        guard let startDate = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: .now)) else {
            return [:]
        }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: .strictStartDate)
        let anchorDate: Date
        if let minutes = interval.minute, minutes > 0 {
            let parts = calendar.dateComponents([.hour, .minute], from: .now)
            let alignedMinute = ((parts.minute ?? 0) / minutes) * minutes
            anchorDate = calendar.date(bySettingHour: parts.hour ?? 0, minute: alignedMinute,
                                       second: 0, of: .now) ?? calendar.startOfDay(for: .now)
        } else {
            anchorDate = calendar.startOfDay(for: .now)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchorDate,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, statisticsCollection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                var totals: [Date: Double] = [:]
                statisticsCollection?.enumerateStatistics(from: startDate, to: .now) { statistics, _ in
                    if let sum = statistics.sumQuantity() {
                        let bucket = interval.minute != nil || interval.second != nil
                            ? statistics.startDate
                            : calendar.startOfDay(for: statistics.startDate)
                        totals[bucket] = valueReader(sum)
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

    private nonisolated static func aggregateExerciseIntervals(collected: [HKQuantityType: [Date: Double]]) -> [ExerciseInterval] {
        var starts = Set<Date>()
        for values in collected.values { starts.formUnion(values.keys) }
        return starts.sorted().compactMap { start in
            let steps = collected[HKQuantityType(.stepCount)]?[start]
            let distance = collected[HKQuantityType(.distanceWalkingRunning)]?[start]
            let energy = collected[HKQuantityType(.activeEnergyBurned)]?[start]
            guard steps != nil || distance != nil || energy != nil else { return nil }
            return ExerciseInterval(start: start, end: start.addingTimeInterval(15 * 60),
                                    steps: steps, distanceKilometers: distance,
                                    activeEnergyKilocalories: energy)
        }
    }
}
