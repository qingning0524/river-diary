import Foundation
import HealthKit
import RiverDiaryCore
import SwiftUI

struct SleepNight: Identifiable, Hashable {
    let date: Date
    var core: TimeInterval
    var deep: TimeInterval
    var rem: TimeInterval
    var awake: TimeInterval
    /// 来源只说明“睡着了”、没有分期时的时长。老设备和部分来源都只有这一种。
    var unspecified: TimeInterval = 0
    /// 这一夜至少有一条睡着样本。false 表示只有清醒/在床记录，属于“未知”，不是 0 小时。
    var hasAsleepSamples: Bool = true

    var id: Date { date }
    var total: TimeInterval { core + deep + rem + unspecified }
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
        // 只有清醒/在床记录的夜晚不算“睡了 0 小时”，不能拉低平均值。
        let measured = nights.filter(\.hasAsleepSamples)
        guard !measured.isEmpty else { return nil }
        return measured.map(\.totalHours).reduce(0, +) / Double(measured.count)
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

    /// HealthKit 样本先映射成平台无关的睡眠区间，再交给 Core 的聚合器：
    /// 重叠来源取并集、未分期计入总睡眠、只有清醒/在床记录保持“未知”。
    private nonisolated static func aggregate(samples: [HKSample]?) -> [SleepNight] {
        let calendar = Calendar.current
        let intervals: [ObservedSleepInterval] = (samples ?? []).compactMap { sample in
            guard let categorySample = sample as? HKCategorySample,
                  let stage = sleepStage(for: categorySample.value) else { return nil }
            return ObservedSleepInterval(
                start: categorySample.startDate,
                end: categorySample.endDate,
                stage: stage
            )
        }

        return SleepNightAggregator.aggregate(intervals, calendar: calendar).map { night in
            SleepNight(
                date: night.day,
                core: night.coverage(for: .core),
                deep: night.coverage(for: .deep),
                rem: night.coverage(for: .rem),
                awake: night.awakeSeconds,
                unspecified: night.coverage(for: .unspecified),
                hasAsleepSamples: night.hasAsleepSamples
            )
        }
    }

    private nonisolated static func sleepStage(for value: Int) -> ObservedSleepInterval.Stage? {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .asleepCore: .core
        case .asleepDeep: .deep
        case .asleepREM: .rem
        case .asleepUnspecified: .unspecified
        case .awake: .awake
        case .inBed: .inBed
        default: nil
        }
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
