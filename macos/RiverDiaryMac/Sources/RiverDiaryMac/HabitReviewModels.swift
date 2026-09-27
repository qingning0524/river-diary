import Foundation

// MARK: - 习惯回顾：全天 AI 理解与个人情境学习
//
// 设计承接 docs/designs/personal-context-learning-strategy.md 第 8/10/12 节：
// 多日观察由 AI 写成可继续对话的回顾卡；用户明确确认后成为可复用个人知识。
// 原始事件纠正仍走单次时间线确认，不与跨天习惯混成同一类答案。
//
// 观测、模型假设、已确认知识三类严格分开：
// - 卡片例子是观测的引用（sourceKey 指回 bundleID + 本地日）；
// - 卡片本身是"AI 观察到的规律"，回答前只是候选；
// - 规则是用户明确授权的知识，带 validFrom，不改写历史。

/// 回顾节奏。默认每周日 20:00；时间可调（见 `HabitReviewTimePreset`）。
enum HabitReviewCadence: String, Codable, CaseIterable, Identifiable, Sendable {
    case everyThreeDays
    case weekly
    case monthly
    case smart
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everyThreeDays: "每 3 天"
        case .weekly: "每周固定时间"
        case .monthly: "每月固定时间"
        case .smart: "智能积累"
        case .manual: "仅手动"
        }
    }

    var detail: String {
        switch self {
        case .everyThreeDays: "每三个当地日"
        case .weekly: "每周固定时间"
        case .monthly: "每月固定时间"
        case .smart: "问题成熟后集中"
        case .manual: "打开本页时生成"
        }
    }

    /// 节奏面板里的第二行说明。
    var alternatives: String {
        switch self {
        case .everyThreeDays: "每周、每月、智能积累也可选"
        case .weekly: "每三天、每月、智能积累也可选"
        case .monthly: "每三天、每周、智能积累也可选"
        case .smart: "每三天、每周、每月也可选"
        case .manual: "其余节奏在更改频率里可选"
        }
    }
}

/// 回顾时间预设：只提供整点档位，避免暴露过多的调度概念。
enum HabitReviewTimePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case morning   // 09:00
    case afternoon // 14:00
    case evening   // 20:00（默认）

    var id: String { rawValue }

    var hour: Int {
        switch self {
        case .morning: 9
        case .afternoon: 14
        case .evening: 20
        }
    }

    var minute: Int { 0 }

    var title: String {
        switch self {
        case .morning: "上午 9:00"
        case .afternoon: "下午 2:00"
        case .evening: "晚上 8:00"
        }
    }
}

/// 卡片类型：跨天个人观察与一次事实补充。
/// 单次事实澄清当前由时间线的「需要你确认」呈现。
enum HabitCardKind: String, Codable, Sendable {
    case pattern
    case fact

    var badgeText: String {
        switch self {
        case .pattern: "个人观察"
        case .fact: "事实补充"
        }
    }
}

/// 卡片状态：candidate → bundled → shown → answered / skipped / expired。
/// 生成时即 bundled（已进包），页面打开标记 shown。
enum HabitCardStatus: String, Codable, Sendable {
    case bundled
    case shown
    case answered
    case skipped
    case expired
}

struct HabitReviewTurn: Codable, Hashable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }

    var id: UUID = UUID()
    var role: Role
    var text: String
    var createdAt: Date = Date()
}

struct HabitContextExample: Codable, Hashable, Identifiable, Sendable {
    var dayKey: String
    var dateText: String
    var timeText: String
    var title: String
    var summary: String
    var evidenceRefs: [String]

    var id: String { "\(dayKey)|\(title)|\(evidenceRefs.first ?? "")" }
}

/// 用户对一个问题的回答类型。
enum HabitAnswerKind: String, Codable, Sendable {
    /// 按卡片展示的范围建立长期规则（含从范围编辑器提交的修改）。
    case longTermRule
    /// 只确认卡片上列出的例子，不建立跨事件规则。
    case onlyTheseExamples
    /// 还不确定 / 跳过：不产生真值，只进入冷却。
    case skip
    /// Resolved through natural-language conversation; no fixed option was selected.
    case conversation
}

/// 一个例子的稳定引用。sourceKey = bundleID + 本地日，
/// 用于"同一次模式被切成许多节点只算一个样本"与跨批次去重。
struct HabitExample: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    /// 本地日键，格式 yyyy-MM-dd。
    var dayKey: String
    /// 展示用短日期，如 9/20。
    var dateText: String
    var duration: TimeInterval
    /// 地点摘要（如"宿舍附近"）；无可靠样本时为"位置暂不确定"。
    var placeSummary: String
    var appName: String
    /// 稳定去重键：bundleID@dayKey。
    var sourceKey: String

    var durationText: String { ActivityFormatter.time(duration) }
}

/// 依据栏的一节：地点 / 活动 / 仍不确定。
struct HabitEvidenceSection: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var headline: String
    var footnote: String
}

/// 一张待确认的问题卡。回答前只是候选，不写入"已确认习惯"。
struct HabitReviewCard: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var kind: HabitCardKind = .pattern
    /// 去重键，如 "pattern:com.openai.codex"。
    var dedupKey: String
    /// 问题标题，如"在宿舍使用 Codex 时，通常算作工作吗？"
    var question: String
    var lead: String
    var examples: [HabitExample]
    var evidence: [HabitEvidenceSection]
    /// AI authored context and dialogue state. Optional to decode existing cards.
    var contextExamples: [HabitContextExample]? = nil
    var evidenceRefs: [String]? = nil
    var suggestedReplies: [String]? = nil
    var conversation: [HabitReviewTurn]? = nil
    var ruleSuggestion: String? = nil
    var conversationResolved: Bool? = nil
    var modelName: String? = nil
    /// 建议归入的类别（来自现有分类器）。
    var proposedCategory: String
    /// 建议范围的应用名。
    var appName: String
    var bundleID: String
    /// 候选地点条件；nil 表示不限地点。
    var placeKey: String?
    var status: HabitCardStatus = .bundled
    var createdAt: Date = Date()
    var answeredAt: Date?
    var answerKind: HabitAnswerKind?
    /// 回答后的范围描述（展示用）。
    var answerScopeText: String?
    /// 回答创建的规则 ID（撤销时按此退役）。
    var createdRuleID: UUID?
    /// "仅这些例子"被固定的样本 sourceKey。
    var markedExampleKeys: [String] = []

    var isPending: Bool { status == .bundled || status == .shown }
}

/// 用户确认过的个人条件规则。
///
/// 既支持早期明确的应用/地点范围，也支持 AI 对话中用户确认的自然语言情境。
struct HabitPersonalRule: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case candidate
        case observing
        case active
        case challenged
        case retired
    }

    enum Origin: String, Codable, Sendable {
        /// 用户明确确认，可直接 active。
        case userConfirmed
        /// 自主挖掘（阶段 3），先观察/影子运行。
        case autoObserved
    }

    var id: UUID = UUID()
    var dedupKey: String
    var conditionBundleID: String
    var conditionAppName: String
    /// 地点条件；nil 表示不限地点。
    var conditionPlaceKey: String?
    /// Natural-language condition confirmed in an AI conversation. This lets
    /// later models apply topic/project/time nuance without widening app rules.
    var naturalLanguageRule: String? = nil
    var supportingEvidenceRefs: [String]? = nil
    var conclusionCategory: String
    /// 给用户看的一句话范围，如"Codex · 宿舍附近"。
    var scopeText: String
    var status: Status = .active
    var origin: Origin = .userConfirmed
    /// 系统何时获知（recordedAt）。
    var recordedAt: Date = Date()
    /// 现实中何时开始适用（validFrom）——"从现在起"不改写过去。
    var validFrom: Date = Date()
    var validTo: Date?
    var supersededBy: UUID?
    var supportingExampleKeys: [String] = []
    var createdFromCardID: UUID?

    /// 规则是否命中当前 bundle（地点条件必须被当前地点满足或不限）。
    func matches(bundleID: String, placeKey: String?) -> Bool {
        guard status == .active, conditionBundleID == bundleID else { return false }
        guard let conditionPlaceKey else { return true }
        return placeKey == conditionPlaceKey
    }
}

struct HabitAIReviewProposal: Decodable, Sendable {
    var topic: String
    var observation: String
    var opening: String
    var suggestedReplies: [String]
    var evidenceRefs: [String]
}

struct HabitAIReviewPayload: Decodable, Sendable {
    var conversations: [HabitAIReviewProposal]
}

struct HabitAIReplyPayload: Decodable, Sendable {
    var reply: String
    var suggestedReplies: [String]
    var ruleSuggestion: String?
    var resolved: Bool
}

enum HabitAIResponseParser {
    static func proposals(_ raw: String, allowedRefs: Set<String>) -> [HabitAIReviewProposal]? {
        guard let payload: HabitAIReviewPayload = decode(raw) else { return nil }
        return payload.conversations.prefix(3).compactMap { proposal in
            let observation = proposal.observation.trimmingCharacters(in: .whitespacesAndNewlines)
            let opening = proposal.opening.trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitized = EvidenceReference.sanitize(proposal.evidenceRefs, allowed: allowedRefs)
            let days = Set(sanitized.kept.compactMap { reference -> String? in
                guard let parsed = EvidenceReference.parse(reference),
                      parsed.kind == .raw || parsed.kind == .browser || parsed.kind == .location else { return nil }
                // The caller validates independent dates by mapping refs to the
                // source day. This parser only enforces multiple local sources.
                return parsed.value
            })
            guard !observation.isEmpty, !opening.isEmpty, days.count >= 2 else { return nil }
            return HabitAIReviewProposal(
                topic: String(proposal.topic.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)),
                observation: String(observation.prefix(360)),
                opening: String(opening.prefix(360)),
                suggestedReplies: proposal.suggestedReplies
                    .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) }
                    .filter { !$0.isEmpty }
                    .prefix(4)
                    .map { $0 },
                evidenceRefs: sanitized.kept
            )
        }
    }

    static func reply(_ raw: String) -> HabitAIReplyPayload? {
        guard let payload: HabitAIReplyPayload = decode(raw) else { return nil }
        let text = payload.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return HabitAIReplyPayload(
            reply: String(text.prefix(800)),
            suggestedReplies: payload.suggestedReplies
                .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) }
                .filter { !$0.isEmpty }
                .prefix(4)
                .map { $0 },
            ruleSuggestion: payload.ruleSuggestion.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)) },
            resolved: payload.resolved
        )
    }

    private static func decode<T: Decodable>(_ raw: String) -> T? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"), start <= end else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(trimmed[start...end].utf8))
    }
}

/// 一份回顾问题包。每个回顾周期只有一个持久化去重键（periodKey）。
struct HabitReviewBatch: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var periodKey: String
    var cadence: HabitReviewCadence
    var createdAt: Date = Date()
    var shownAt: Date?
    var cardIDs: [UUID] = []
    var introTitle: String = ""
    var introDetail: String = "AI 已把相似记录放在一起；平时的活动继续自动整理。"
    var estimatedSeconds: Int = 0
}

// MARK: - 节奏调度

extension HabitReviewCadence {
    /// 当前周期的去重键与到期时刻。到期即"现在可以为本周期生成问题包"。
    /// 不回补错过的历史周期：应用关闭后恢复，只处理当前周期。
    func currentPeriod(now: Date, time: HabitReviewTimePreset, calendar: Calendar) -> (key: String, dueDate: Date) {
        let startOfDay = calendar.startOfDay(for: now)
        let dueTime = DateComponents(hour: time.hour, minute: time.minute)
        switch self {
        case .weekly:
            let week = calendar.dateInterval(of: .weekOfYear, for: startOfDay)
            let weekStart = week?.start ?? startOfDay
            // 默认周日为回顾日：周起点 + (目标 weekday - 周首日) 推出本周回顾日。
            let targetWeekday = 1 // 周日
            let offset = (targetWeekday - calendar.firstWeekday + 7) % 7
            var due = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? startOfDay
            due = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: due) ?? due
            let key = "w-" + Self.dayStamp(due, calendar: calendar)
            return (key, due)
        case .everyThreeDays:
            // 以 2026-01-01 为锚点的三天块；块首日到达所选时间后开放。
            guard let anchor = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)) else {
                return ("3d-" + Self.dayStamp(startOfDay, calendar: calendar), startOfDay)
            }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: anchor), to: startOfDay).day ?? 0
            // Swift 的 % 向零截断：锚点之前的负数天会算出"未来"的块首。
            // 统一向下取整（floorMod），锚点前后语义一致。
            let blockOffset = days >= 0 ? days - (days % 3) : days - ((days % 3) + 3) % 3
            let blockStart = calendar.date(byAdding: .day, value: blockOffset, to: calendar.startOfDay(for: anchor)) ?? startOfDay
            let due = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: blockStart) ?? blockStart
            return ("3d-" + Self.dayStamp(blockStart, calendar: calendar), due)
        case .monthly:
            // 月末集中处理；当月所选日期不存在时落在最后一天——这里固定取月末。
            let month = calendar.dateInterval(of: .month, for: startOfDay)
            let monthStart = month?.start ?? startOfDay
            let lastDay = calendar.date(byAdding: DateComponents(day: -1, second: 0), to: month?.end ?? startOfDay) ?? startOfDay
            let due = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: calendar.startOfDay(for: lastDay)) ?? lastDay
            return ("m-" + Self.monthStamp(now, calendar: calendar), due)
        case .smart, .manual:
            // 智能积累的到期由候选数量与间隔决定；手动没有周期。
            let key = Self.dayStamp(startOfDay, calendar: calendar)
            return ((self == .smart ? "smart-" : "manual-") + key, .distantPast)
        }
    }

    /// 智能积累 / 手动以外，判断当前周期是否已到期。
    func isDue(now: Date, time: HabitReviewTimePreset, calendar: Calendar) -> Bool {
        let period = currentPeriod(now: now, time: time, calendar: calendar)
        return now >= period.dueDate
    }

    /// 面向用户的下一次回顾时间（用于空态与节奏面板）。
    func nextReviewText(now: Date, time: HabitReviewTimePreset, calendar: Calendar) -> String? {
        switch self {
        case .manual:
            return nil
        case .smart:
            return "攒够 3 个值得判断的问题时出现，最长一个月检查一次"
        case .weekly, .everyThreeDays, .monthly:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = self == .monthly ? "M月d日" : "M月d日 EEE"
            // 已生成过当前周期的问题包后，再显示本周期已过去的时刻是误导；
            // 推进到下一个周期的到期点。
            var due = currentPeriod(now: now, time: time, calendar: calendar).dueDate
            if now >= due {
                let step: DateComponents
                switch self {
                case .weekly: step = DateComponents(day: 7)
                case .everyThreeDays: step = DateComponents(day: 3)
                default: step = DateComponents(day: 28)
                }
                due = calendar.date(byAdding: step, to: due) ?? due
            }
            let timeText: String
            switch time {
            case .morning: timeText = "上午 9:00"
            case .afternoon: timeText = "下午 2:00"
            case .evening: timeText = "晚上 8:00"
            }
            return "\(formatter.string(from: due)) \(timeText)"
        }
    }

    static func dayStamp(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func monthStamp(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}
