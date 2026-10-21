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
    /// 按 Core 口径判定为午睡的部分（含在 total 内）。
    var nap: TimeInterval = 0

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

/// 一次体能训练。比步数更有语义：类型、时长、距离和能量都能直接对上“今天去游泳了”。
struct WorkoutSummary: Identifiable, Hashable {
    let id: String
    let start: Date
    let end: Date
    let activityName: String
    let energyKcal: Double?
    let distanceKm: Double?
}

/// Apple 健康的 State of Mind（iOS 18+）。效价 -1…1，写入前夹紧。
struct StateOfMindSummary: Identifiable, Hashable {
    let id: String
    let date: Date
    let valence: Double
    let kindLabel: String
}

@MainActor
final class HealthKitStore: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var isLoading = false
    @Published private(set) var nights: [SleepNight] = []
    @Published private(set) var exerciseDays: [ExerciseDay] = []
    @Published private(set) var exerciseIntervals: [ExerciseInterval] = []
    @Published private(set) var workouts: [WorkoutSummary] = []
    @Published private(set) var stateOfMind: [StateOfMindSummary] = []
    @Published private(set) var errorMessage: String?

    var onHealthSnapshotChanged: (([SleepNight], [ExerciseDay], [ExerciseInterval], [WorkoutSummary], [StateOfMindSummary]) async -> Void)?

    private let healthStore = HKHealthStore()
    private let connectionKey = "has-connected-healthkit"
    private var refreshBatch = HealthRefreshBatch()

    init(loadOnInit: Bool = true) {
        if UserDefaults.standard.bool(forKey: connectionKey) {
            isAuthorized = true
            if loadOnInit { loadHealth() }
        }
    }

    /// 健康来源的当前状态。HealthKit 读权限无法查询，所以授权状态永远传 nil：
    /// 能用样本/失败如实说明，不会因为“请求成功过”就宣称已授权。
    var sourceStatus: HealthSourceStatus {
        let samples = nights.map(\.date) + exerciseDays.map(\.date)
        return HealthSourceStatusEvaluator.evaluate(
            isSupported: HKHealthStore.isHealthDataAvailable(),
            isAuthorized: nil,
            hasSamples: !samples.isEmpty,
            lastSampleAt: samples.max(),
            failure: errorMessage,
            now: Date()
        )
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

        var readTypes: Set<HKObjectType> = [
            HKCategoryType(.sleepAnalysis),
            HKQuantityType(.stepCount),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.activeEnergyBurned),
            HKObjectType.workoutType()
        ]
        if #available(iOS 18.0, *) {
            readTypes.insert(HKObjectType.stateOfMindType())
        }

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
        loadWorkouts(generation: generation)
        loadStateOfMind(generation: generation)
    }

    private func loadStateOfMind(generation: UUID) {
        guard #available(iOS 18.0, *) else {
            Task { await notifySnapshotChanged(part: .stateOfMind, generation: generation) }
            return
        }
        let start = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: HKObjectType.stateOfMindType(),
            predicate: predicate,
            limit: 100,
            sortDescriptors: [sort]
        ) { [weak self] _, samples, error in
            let mapped = (samples as? [HKStateOfMind] ?? []).map { sample in
                StateOfMindSummary(
                    id: sample.uuid.uuidString,
                    date: sample.startDate,
                    valence: StateOfMindReading.normalizedValence(sample.valence),
                    kindLabel: Self.stateOfMindKindLabel(sample.kind)
                )
            }
            Task { @MainActor [weak self] in
                guard let self, self.refreshBatch.accepts(generation) else { return }
                self.stateOfMind = mapped
                if let error {
                    self.errorMessage = error.localizedDescription
                }
                await self.notifySnapshotChanged(part: .stateOfMind, generation: generation)
            }
        }
        healthStore.execute(query)
    }

    @available(iOS 18.0, *)
    private nonisolated static func stateOfMindKindLabel(_ kind: HKStateOfMind.Kind) -> String {
        switch kind {
        case .momentaryEmotion: "此刻情绪"
        case .dailyMood: "今日心情"
        @unknown default: "心情记录"
        }
    }

    private func loadWorkouts(generation: UUID) {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: predicate,
            limit: 100,
            sortDescriptors: [sort]
        ) { [weak self] _, samples, error in
            let workouts = (samples as? [HKWorkout] ?? []).map(Self.summary(for:))
            Task { @MainActor [weak self] in
                guard let self, self.refreshBatch.accepts(generation) else { return }
                self.workouts = workouts
                if let error {
                    self.errorMessage = error.localizedDescription
                }
                await self.notifySnapshotChanged(part: .workouts, generation: generation)
            }
        }
        healthStore.execute(query)
    }

    private nonisolated static func summary(for workout: HKWorkout) -> WorkoutSummary {
        WorkoutSummary(
            id: workout.uuid.uuidString,
            start: workout.startDate,
            end: workout.endDate,
            activityName: workoutName(workout.workoutActivityType),
            energyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
            distanceKm: workout.totalDistance?.doubleValue(for: .meterUnit(with: .kilo))
        )
    }

    nonisolated static func workoutName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: "跑步"
        case .walking: "步行"
        case .cycling: "骑行"
        case .swimming: "游泳"
        case .hiking: "徒步"
        case .yoga: "瑜伽"
        case .pilates: "普拉提"
        case .cardioDance, .socialDance: "舞蹈"
        case .rowing: "划船"
        case .elliptical: "椭圆机"
        case .stairClimbing: "爬楼梯"
        case .jumpRope: "跳绳"
        case .highIntensityIntervalTraining: "高强度间歇"
        case .functionalStrengthTraining, .traditionalStrengthTraining: "力量训练"
        case .crossTraining: "交叉训练"
        case .mixedCardio: "混合有氧"
        case .climbing: "攀岩"
        case .boxing: "拳击"
        case .martialArts: "武术"
        case .tennis: "网球"
        case .badminton: "羽毛球"
        case .tableTennis: "乒乓球"
        case .squash, .racquetball: "壁球"
        case .soccer: "足球"
        case .basketball: "篮球"
        case .volleyball: "排球"
        case .baseball: "棒球"
        case .golf: "高尔夫"
        case .skatingSports: "滑冰"
        case .surfingSports: "冲浪"
        default: "其他运动"
        }
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
        await onHealthSnapshotChanged?(nights, exerciseDays, exerciseIntervals, workouts, stateOfMind)
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
                stage: stage,
                sourcePriority: sleepSourcePriority(for: categorySample)
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
                hasAsleepSamples: night.hasAsleepSamples,
                nap: night.napSeconds
            )
        }
    }

    /// 同一段睡眠被多个来源上报时，Apple Watch 的分期最可信，其次是 iPhone，
    /// 其他来源（第三方 App、手动记录）最后。
    private nonisolated static func sleepSourcePriority(for sample: HKCategorySample) -> Int {
        let source = sample.sourceRevision.source
        let identity = (source.name + " " + source.bundleIdentifier).lowercased()
        if identity.contains("watch") { return 20 }
        if identity.contains("iphone") || identity.contains("phone") { return 10 }
        return 5
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
