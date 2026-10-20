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
    /// 同一段睡眠被多个来源同时上报时，数值更大者优先（例如 Apple Watch > iPhone > 其他）。
    /// 相同优先级之间仍按并集去重，不互相覆盖。
    public let sourcePriority: Int

    public init(start: Date, end: Date, stage: Stage, sourcePriority: Int = 0) {
        self.start = start
        self.end = end
        self.stage = stage
        self.sourcePriority = sourcePriority
    }
}

/// 睡眠归属口径。规则一旦发布就带上版本号，未来调整不得静默重解释旧数据。
public struct SleepNightPolicy: Sendable, Equatable {
    public enum Version: String, Codable, Sendable {
        /// v1：按醒来日分夜；白天且不超过 3 小时的一段睡眠记为午睡。
        case v1 = "wake-day-v1"
    }

    public let version: Version
    public let napMaximumDuration: TimeInterval
    public let napEarliestHour: Int
    public let napLatestStartHour: Int

    public static let current = SleepNightPolicy()

    public init(
        version: Version = .v1,
        napMaximumDuration: TimeInterval = 3 * 3600,
        napEarliestHour: Int = 6,
        napLatestStartHour: Int = 20
    ) {
        self.version = version
        self.napMaximumDuration = napMaximumDuration
        self.napEarliestHour = napEarliestHour
        self.napLatestStartHour = napLatestStartHour
    }

    public func isNap(start: Date, duration: TimeInterval, calendar: Calendar) -> Bool {
        guard duration > 0, duration <= napMaximumDuration else { return false }
        let hour = calendar.component(.hour, from: start)
        return hour >= napEarliestHour && hour < napLatestStartHour
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
    /// 全部睡着时间的并集，包含午睡。
    public let asleepSeconds: TimeInterval
    /// 其中按当前口径判定为午睡的部分。
    public let napSeconds: TimeInterval
    public let awakeSeconds: TimeInterval
    public let stageCoverage: [ObservedSleepInterval.Stage: TimeInterval]
    public let hasAsleepSamples: Bool
    /// 产生这条汇总时使用的归属口径与日历时区，便于解释与迁移。
    public let policyVersion: SleepNightPolicy.Version
    public let timeZoneIdentifier: String

    public init(
        day: Date,
        asleepSeconds: TimeInterval,
        awakeSeconds: TimeInterval,
        stageCoverage: [ObservedSleepInterval.Stage: TimeInterval],
        hasAsleepSamples: Bool,
        napSeconds: TimeInterval = 0,
        policyVersion: SleepNightPolicy.Version = .v1,
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) {
        self.day = day
        self.asleepSeconds = asleepSeconds
        self.napSeconds = napSeconds
        self.awakeSeconds = awakeSeconds
        self.stageCoverage = stageCoverage
        self.hasAsleepSamples = hasAsleepSamples
        self.policyVersion = policyVersion
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    /// 夜间睡眠：总睡眠减去午睡。
    public var nightSeconds: TimeInterval { max(0, asleepSeconds - napSeconds) }

    public func coverage(for stage: ObservedSleepInterval.Stage) -> TimeInterval {
        stageCoverage[stage] ?? 0
    }

    /// 未分期之外的已分期睡眠覆盖；与 `asleepSeconds` 的差值即未分期部分。
    public var stagedSeconds: TimeInterval {
        coverage(for: .core) + coverage(for: .deep) + coverage(for: .rem)
    }
}

public enum SleepNightAggregator {
    /// 把观测区间按醒来日期分组。日期归属使用传入的日历与时区，口径由 `policy` 固定。
    public static func aggregate(
        _ intervals: [ObservedSleepInterval],
        calendar: Calendar,
        policy: SleepNightPolicy = .current
    ) -> [ObservedSleepNight] {
        let valid = intervals.filter { $0.end > $0.start }
        guard !valid.isEmpty else { return [] }

        var groups: [Date: [ObservedSleepInterval]] = [:]
        for interval in valid {
            let day = calendar.startOfDay(for: interval.end)
            groups[day, default: []].append(interval)
        }

        return groups.map { day, samples in
            // 先按来源优先级裁掉被更高优先级覆盖的部分，再做并集：
            // Watch 报的睡着不会被 iPhone 同时报的清醒覆盖，反之亦然。
            let retained = prioritizedPieces(samples)
            let asleep = retained.filter { $0.stage.isAsleep }
            var coverage: [ObservedSleepInterval.Stage: TimeInterval] = [:]
            for stage in ObservedSleepInterval.Stage.allCases {
                let seconds = unionSeconds(retained.filter { $0.stage == stage }.map { ($0.start, $0.end) })
                if seconds > 0 { coverage[stage] = seconds }
            }
            // 连续睡眠块用于区分“夜间睡眠”和“白天午睡”。
            let asleepBlocks = mergedRanges(asleep.map { ($0.start, $0.end) })
            let napSeconds = asleepBlocks.reduce(0) { total, block in
                let duration = block.1.timeIntervalSince(block.0)
                return policy.isNap(start: block.0, duration: duration, calendar: calendar)
                    ? total + duration
                    : total
            }
            return ObservedSleepNight(
                day: day,
                asleepSeconds: asleepBlocks.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) },
                awakeSeconds: unionSeconds(retained.filter { $0.stage == .awake }.map { ($0.start, $0.end) }),
                stageCoverage: coverage,
                hasAsleepSamples: !asleep.isEmpty,
                napSeconds: napSeconds,
                policyVersion: policy.version,
                timeZoneIdentifier: calendar.timeZone.identifier
            )
        }
        .sorted { $0.day > $1.day }
    }

    private struct RetainedPiece {
        let start: Date
        let end: Date
        let stage: ObservedSleepInterval.Stage
    }

    /// 从高优先级到低优先级依次认领时间；被更高优先级占用的部分会被裁掉。
    /// 同优先级之间不互斥，保留完整区间，后续并集去重。
    private static func prioritizedPieces(_ samples: [ObservedSleepInterval]) -> [RetainedPiece] {
        let ordered = samples.sorted {
            if $0.sourcePriority != $1.sourcePriority { return $0.sourcePriority > $1.sourcePriority }
            return $0.start < $1.start
        }
        var claimed: [(Date, Date)] = []
        var retained: [RetainedPiece] = []
        var index = 0
        while index < ordered.count {
            let priority = ordered[index].sourcePriority
            var group: [ObservedSleepInterval] = []
            while index < ordered.count, ordered[index].sourcePriority == priority {
                group.append(ordered[index])
                index += 1
            }
            for sample in group {
                for (start, end) in subtract(claimed, from: (sample.start, sample.end)) {
                    retained.append(RetainedPiece(start: start, end: end, stage: sample.stage))
                }
            }
            // 这一层完整认领，即使部分已被更高优先级覆盖也不影响后续裁剪。
            claimed = mergedRanges(claimed + group.map { ($0.start, $0.end) })
        }
        return retained
    }

    /// 返回 `interval` 中未被 `covered` 覆盖的片段。
    static func subtract(_ covered: [(Date, Date)], from interval: (Date, Date)) -> [(Date, Date)] {
        var pieces: [(Date, Date)] = []
        var cursor = interval.0
        for (start, end) in mergedRanges(covered) where end > interval.0 && start < interval.1 {
            if start > cursor {
                pieces.append((cursor, min(start, interval.1)))
            }
            cursor = max(cursor, end)
            if cursor >= interval.1 { break }
        }
        if cursor < interval.1 {
            pieces.append((cursor, interval.1))
        }
        return pieces.filter { $0.1 > $0.0 }
    }

    static func mergedRanges(_ ranges: [(Date, Date)]) -> [(Date, Date)] {
        let sorted = ranges.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var merged: [(Date, Date)] = []
        for range in sorted {
            if let last = merged.last, range.0 <= last.1 {
                merged[merged.count - 1] = (last.0, max(last.1, range.1))
            } else {
                merged.append(range)
            }
        }
        return merged
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
