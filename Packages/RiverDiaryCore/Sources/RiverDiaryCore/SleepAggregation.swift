import Foundation

/// 一次睡眠观测，平台/来源无关。HealthKit 的原始样本要先映射成这个类型，
/// 再交给 `SleepNightAggregator`，这样口径可以脱离具体 SDK 做确定性测试。
public struct ObservedSleepInterval: Sendable, Hashable {
    public enum Stage: String, Codable, Sendable, CaseIterable {
        case core
        case deep
        case rem
        /// 部分设备/来源只给“睡着了”，没有分期。
        case unspecified
        case awake
        /// 仅在床上，不等于睡着。
        case inBed

        public var isAsleep: Bool {
            switch self {
            case .core, .deep, .rem, .unspecified: true
            case .awake, .inBed: false
            }
        }
    }

    public let start: Date
    public let end: Date
    public let stage: Stage

    public init(start: Date, end: Date, stage: Stage) {
        self.start = start
        self.end = end
        self.stage = stage
    }
}

/// 按“醒来那天”汇总的一夜睡眠。
///
/// - `asleepSeconds` 是所有睡着区间（含未分期）的**并集**，重叠来源不会重复累加；
/// - `stageCoverage` 是各分期自己的并集覆盖，可能互相重叠，因此它只回答
///   “这个分期有多少覆盖”，不应相加当作总睡眠；
/// - `hasAsleepSamples == false` 表示这一夜只有清醒/在床记录，属于“未知”，
///   不能显示成“睡了 0 小时”。
public struct ObservedSleepNight: Sendable, Equatable {
    public let day: Date
    public let asleepSeconds: TimeInterval
    public let awakeSeconds: TimeInterval
    public let stageCoverage: [ObservedSleepInterval.Stage: TimeInterval]
    public let hasAsleepSamples: Bool

    public init(
        day: Date,
        asleepSeconds: TimeInterval,
        awakeSeconds: TimeInterval,
        stageCoverage: [ObservedSleepInterval.Stage: TimeInterval],
        hasAsleepSamples: Bool
    ) {
        self.day = day
        self.asleepSeconds = asleepSeconds
        self.awakeSeconds = awakeSeconds
        self.stageCoverage = stageCoverage
        self.hasAsleepSamples = hasAsleepSamples
    }

    public func coverage(for stage: ObservedSleepInterval.Stage) -> TimeInterval {
        stageCoverage[stage] ?? 0
    }

    /// 未分期之外的已分期睡眠覆盖；与 `asleepSeconds` 的差值即未分期部分。
    public var stagedSeconds: TimeInterval {
        coverage(for: .core) + coverage(for: .deep) + coverage(for: .rem)
    }
}

public enum SleepNightAggregator {
    /// 把观测区间按醒来日期分组。日期归属使用传入的日历与时区，调用方需固定口径。
    public static func aggregate(
        _ intervals: [ObservedSleepInterval],
        calendar: Calendar
    ) -> [ObservedSleepNight] {
        let valid = intervals.filter { $0.end > $0.start }
        guard !valid.isEmpty else { return [] }

        var groups: [Date: [ObservedSleepInterval]] = [:]
        for interval in valid {
            let day = calendar.startOfDay(for: interval.end)
            groups[day, default: []].append(interval)
        }

        return groups.map { day, samples in
            let asleep = samples.filter { $0.stage.isAsleep }
            var coverage: [ObservedSleepInterval.Stage: TimeInterval] = [:]
            for stage in ObservedSleepInterval.Stage.allCases {
                let seconds = unionSeconds(samples.filter { $0.stage == stage }.map { ($0.start, $0.end) })
                if seconds > 0 { coverage[stage] = seconds }
            }
            return ObservedSleepNight(
                day: day,
                asleepSeconds: unionSeconds(asleep.map { ($0.start, $0.end) }),
                awakeSeconds: unionSeconds(samples.filter { $0.stage == .awake }.map { ($0.start, $0.end) }),
                stageCoverage: coverage,
                hasAsleepSamples: !asleep.isEmpty
            )
        }
        .sorted { $0.day > $1.day }
    }

    /// 重叠区间的并集时长。相邻区间（结束等于下一次开始）同样合并。
    static func unionSeconds(_ intervals: [(Date, Date)]) -> TimeInterval {
        let sorted = intervals
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var currentStart: Date?
        var currentEnd: Date?
        for (start, end) in sorted {
            if let activeEnd = currentEnd, start <= activeEnd {
                currentEnd = max(activeEnd, end)
            } else {
                if let activeStart = currentStart, let activeEnd = currentEnd {
                    total += activeEnd.timeIntervalSince(activeStart)
                }
                currentStart = start
                currentEnd = end
            }
        }
        if let activeStart = currentStart, let activeEnd = currentEnd {
            total += activeEnd.timeIntervalSince(activeStart)
        }
        return total
    }
}
