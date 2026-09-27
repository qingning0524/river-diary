import Foundation

// MARK: - Legacy 习惯候选生成（不再接入生产调度）
//
// 保留旧数据兼容与既有规则回归；当前 macOS 习惯回顾不调用此引擎。
// 设计承接 personal-context-learning-strategy.md 的早期本机阶段：
// 从最近的独立日期里找重复出现的应用活动模式，生成"规律确认卡"候选。
// 只做本机统计与几何/时间判断；内容语义留给后续阶段。
//
// 关键约束（都来自设计文档，逐条可测）：
// - 习惯按独立日期累计，不能由一日密集采样得出；
// - 同一次模式被切成许多原始片段，一天只计一个样本；
// - 已确认规则覆盖的范围不再提问；
// - 跳过的问题同范围冷却 7 天；"仅这些例子"冷却 14 天，且新卡只用新例子；
// - 冷启动一次最多 5 张，没有足够价值就 0 张；
// - 事件 ID 基于原始事件与稳定分段：例子 sourceKey = bundleID@本地日。

enum HabitCandidateEngine {
    /// 引擎配置。全部是待试运行校准的初始参数。
    struct Thresholds {
        /// 观察窗口：最近多少个完整本地日（不含今天——今天还没过完）。
        var windowDays = 14
        /// 单日至少多少前台时长才算一个有效样本。
        var minDailyDuration: TimeInterval = 20 * 60
        /// 至少多少个独立日重复出现才值得问。
        var minDays = 3
        /// 例子最后出现距今超过该天数视为旧生活阶段，不再问。
        var staleDays = 10
        /// 冷启动一次最多展示几张。
        var maxCards = 5
        /// 跳过后的冷却天数。
        var skipCooldownDays = 7
        /// "仅这些例子"后的冷却天数。
        var caseExampleCooldownDays = 14
    }

    /// 每个候选 bundle 的单日统计。
    struct DayUsage {
        var dayKey: String
        var date: Date
        var duration: TimeInterval
        var appName: String
        var placeName: String?
    }

    struct Candidate {
        var bundleID: String
        var appName: String
        var category: String
        var days: [DayUsage]
        var totalDuration: TimeInterval
        /// 例子中一致出现的地点名（全部有效样本同名才算一致）。
        var consistentPlaceName: String?
    }

    /// 从会话里统计每个 bundle 的独立日活动。
    /// - Parameters:
    ///   - sessions: 观察窗口内的全部会话（未过滤也可，引擎会按 isRecordable 过滤）。
    ///   - placeNameForDay: 本地日 → 可靠地点名（来自同时段位置样本）。
    ///   - now: 当前时刻。
    static func candidates(
        sessions: [ActivitySession],
        placeNameForDay: [String: String],
        now: Date,
        calendar: Calendar = .current,
        thresholds: Thresholds = Thresholds()
    ) -> [Candidate] {
        let todayStart = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -thresholds.windowDays, to: todayStart) else { return [] }
        let staleCutoff = calendar.date(byAdding: .day, value: -thresholds.staleDays, to: todayStart) ?? windowStart

        // bundleID → dayKey → (时长, 最常见应用名)
        var byBundle: [String: [String: (duration: TimeInterval, appName: String, date: Date)]] = [:]
        for session in sessions where ActivityClassifier.isRecordable(appName: session.appName, bundleID: session.bundleID) {
            let dayKey = session.dayKey
            guard let dayDate = DiaryEntry.dateFormatter.date(from: dayKey),
                  dayDate >= windowStart, dayDate < todayStart else { continue }
            var day = byBundle[session.bundleID]?[dayKey]
                ?? (duration: 0, appName: session.appName, date: dayDate)
            day.duration += session.duration
            byBundle[session.bundleID, default: [:]][dayKey] = day
        }

        var result: [Candidate] = []
        for (bundleID, days) in byBundle {
            let usages: [DayUsage] = days.values.compactMap { day in
                guard day.duration >= thresholds.minDailyDuration else { return nil }
                return DayUsage(
                    dayKey: Self.dayKey(for: day.date),
                    date: day.date,
                    duration: day.duration,
                    appName: day.appName,
                    placeName: placeNameForDay[Self.dayKey(for: day.date)]
                )
            }.sorted { $0.date < $1.date }
            guard usages.count >= thresholds.minDays else { continue }
            // 旧生活阶段：最近的例子太旧就不问，避免"暑假的规律"开学后还在弹。
            guard let lastDate = usages.last?.date, lastDate >= staleCutoff else { continue }

            let total = usages.reduce(TimeInterval(0)) { $0 + $1.duration }
            let appName = dominantAppName(in: usages)
            let category = ActivityClassifier.category(appName: appName, title: nil)
            let placeNames = usages.compactMap(\.placeName)
            let consistent = placeNames.count == usages.count && Set(placeNames).count == 1 ? placeNames.first : nil
            result.append(Candidate(
                bundleID: bundleID,
                appName: appName,
                category: category,
                days: usages,
                totalDuration: total,
                consistentPlaceName: consistent
            ))
        }
        // 复用价值排序：先独立日数，再总时长。
        return result.sorted {
            if $0.days.count != $1.days.count { return $0.days.count > $1.days.count }
            return $0.totalDuration > $1.totalDuration
        }
    }

    /// 把候选过滤成值得展示的卡片输入：应用已确认规则、冷却，并剔除已被
    /// "仅这些例子"固定过、或被退役规则支持过的日子——返回的候选**只含新例子**，
    /// 保证"新卡只用新例子"的不变量（同一次模式被切成的多天里，已回答过的
    /// 日子不会再出现在下一张卡上）。
    static func worthwhileCandidates(
        from candidates: [Candidate],
        rules: [HabitPersonalRule],
        cards: [HabitReviewCard],
        now: Date,
        calendar: Calendar = .current,
        thresholds: Thresholds = Thresholds()
    ) -> [Candidate] {
        candidates.compactMap { candidate in
            let dedupKey = Self.dedupKey(bundleID: candidate.bundleID)

            // 1) 已确认的活跃规则覆盖同一范围：不再询问。
            //    地点数据暂时缺失时（consistentPlaceName == nil）视为已被
            //    地点级规则覆盖，避免降级出第二条更宽的规则。
            let hasActiveRule = rules.contains { rule in
                rule.status == .active
                    && rule.conditionBundleID == candidate.bundleID
                    && (rule.conditionPlaceKey == nil
                        || candidate.consistentPlaceName == nil
                        || rule.conditionPlaceKey == candidate.consistentPlaceName)
            }
            if hasActiveRule { return nil }

            // 2) 同范围的问题在冷却期内。
            let sameKeyCards = cards.filter { $0.dedupKey == dedupKey }
            for card in sameKeyCards {
                guard let answeredAt = card.answeredAt else { continue }
                let cooldown: Int
                switch card.answerKind {
                case .skip: cooldown = thresholds.skipCooldownDays
                case .onlyTheseExamples: cooldown = thresholds.caseExampleCooldownDays
                case .longTermRule, .conversation, .none: cooldown = thresholds.skipCooldownDays
                }
                if let unblock = calendar.date(byAdding: .day, value: cooldown, to: answeredAt), now < unblock {
                    return nil
                }
            }

            // 3) 只保留未被固定过的新例子；不足 minDays 就不问。
            let usedKeys = Set(
                sameKeyCards.flatMap(\.markedExampleKeys)
                    + rules.filter { $0.conditionBundleID == candidate.bundleID }.flatMap(\.supportingExampleKeys)
            )
            let freshDays = candidate.days.filter { !usedKeys.contains(exampleKey(bundleID: candidate.bundleID, dayKey: $0.dayKey)) }
            guard freshDays.count >= thresholds.minDays else { return nil }
            // 旧生活阶段判定基于新例子：全部新例子都太旧就不问。
            let todayStart = calendar.startOfDay(for: now)
            guard let lastDate = freshDays.last?.date,
                  lastDate >= (calendar.date(byAdding: .day, value: -thresholds.staleDays, to: todayStart) ?? todayStart) else { return nil }

            var filtered = candidate
            filtered.days = freshDays
            filtered.totalDuration = freshDays.reduce(TimeInterval(0)) { $0 + $1.duration }
            let placeNames = freshDays.compactMap(\.placeName)
            filtered.consistentPlaceName = (placeNames.count == freshDays.count && Set(placeNames).count == 1) ? placeNames.first : nil
            return filtered
        }
    }

    /// 生成规律确认卡（阶段 1 只有规律卡；事实卡等地点命名接入后补充）。
    static func makePatternCard(
        candidate: Candidate,
        now: Date,
        calendar: Calendar = .current
    ) -> HabitReviewCard {
        let dayCount = candidate.days.count
        let question: String
        if let place = candidate.consistentPlaceName {
            question = "在\(place)附近使用 \(candidate.appName) 时，通常算作\(candidate.category)吗？"
        } else {
            question = "最近常用 \(candidate.appName)，通常算作\(candidate.category)吗？"
        }

        let lead = dayCount == 3
            ? "三个不同日期的记录很相似。你的选择会决定今后如何归类。"
            : "\(dayCount) 个不同日期的记录很相似。你的选择会决定今后如何归类。"

        // 例子最多展示 3 个：优先时长最大的三天，再按日期升序排列。
        let exampleDays = candidate.days
            .sorted { $0.duration > $1.duration }
            .prefix(3)
            .sorted { $0.date < $1.date }
            .map { day in
                HabitExample(
                    dayKey: day.dayKey,
                    dateText: shortDateText(day.date),
                    duration: day.duration,
                    placeSummary: day.placeName.map { "\($0)附近" } ?? "位置暂不确定",
                    appName: day.appName,
                    sourceKey: exampleKey(bundleID: candidate.bundleID, dayKey: day.dayKey)
                )
            }

        let namedDays = candidate.days.filter { $0.placeName != nil }.count
        var evidence: [HabitEvidenceSection] = [
            HabitEvidenceSection(
                id: "place",
                title: "地点",
                headline: candidate.consistentPlaceName.map { "同时段位置样本指向「\($0)」" } ?? "位置样本还不完整",
                footnote: namedDays > 0
                    ? "\(dayCount) 天里有 \(namedDays) 天有有效位置样本（地名来自定位，尚未由你确认）"
                    : "这些日子没有可靠的位置样本"
            ),
            HabitEvidenceSection(
                id: "activity",
                title: "活动",
                headline: "\(candidate.appName) 的持续前台记录",
                footnote: "与锁屏、短暂切换分别计算 · \(dayCount) 个不同日期"
            ),
        ]
        // 项目身份在阶段 1 不可辨认：如实展示为仍不确定，规则先按应用与地点生效。
        evidence.append(HabitEvidenceSection(
            id: "unknown",
            title: "还不确定",
            headline: "例子里的具体项目或主题还不清楚",
            footnote: "确认后先按应用与地点生效；之后能识别项目时可以再收窄"
        ))

        return HabitReviewCard(
            kind: .pattern,
            dedupKey: dedupKey(bundleID: candidate.bundleID),
            question: question,
            lead: lead,
            examples: Array(exampleDays),
            evidence: evidence,
            proposedCategory: candidate.category,
            appName: candidate.appName,
            bundleID: candidate.bundleID,
            placeKey: candidate.consistentPlaceName,
            createdAt: now
        )
    }

    // MARK: Keys

    static func dedupKey(bundleID: String) -> String { "pattern:\(bundleID)" }

    static func exampleKey(bundleID: String, dayKey: String) -> String { "\(bundleID)@\(dayKey)" }

    static func dayKey(for date: Date) -> String { DiaryEntry.dateFormatter.string(from: date) }

    static func shortDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private static func dominantAppName(in usages: [DayUsage]) -> String {
        var counts: [String: Int] = [:]
        for usage in usages { counts[usage.appName, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key ?? usages.first?.appName ?? ""
    }
}
