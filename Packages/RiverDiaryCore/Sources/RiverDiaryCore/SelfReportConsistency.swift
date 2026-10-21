import Foundation

/// 同一天的客观记录。字段缺失表示“没有可用证据”，不是 0。
public struct SelfReportFacts: Sendable, Equatable {
    public var sleepHours: Double?
    public var steps: Int?
    public var screenMinutes: Int?
    public var completedItems: Int?

    public init(
        sleepHours: Double? = nil,
        steps: Int? = nil,
        screenMinutes: Int? = nil,
        completedItems: Int? = nil
    ) {
        self.sleepHours = sleepHours
        self.steps = steps
        self.screenMinutes = screenMinutes
        self.completedItems = completedItems
    }
}

/// 规则版反自欺：只在自述与同一天的客观记录“明显”相反时返回一句话。
///
/// 边界：
/// - 不接模型、不做语义推断，只匹配有限的中文自述短语；
/// - 阈值故意取保守值，宁可漏报，不把普通感慨判成矛盾；
/// - 返回句只陈述“你写到什么 / 记录是什么”，不评价真假、不要求改正；
/// - 没有对应客观数据时永远返回 nil。
public enum SelfReportConsistency {
    /// 低于 5 小时仍说“睡得很好/睡够了”才算明显相反。
    public static let sleepContradictionHours = 5.0
    /// 少于 1500 步仍说“走了很多/运动很多”才算明显相反。
    public static let stepsContradictionCount = 1_500
    /// 超过 6 小时屏幕仍说“很少看屏幕/没怎么碰手机”才算明显相反。
    public static let screenContradictionMinutes = 360
    /// 至少 3 项完成事项仍说“什么都没做”才算明显相反。
    public static let completedContradictionCount = 3

    private static let sleepClaims = [
        "睡得很好", "睡得不错", "睡够了", "睡饱了", "睡眠很好", "睡到自然醒"
    ]
    private static let stepClaims = [
        "走了很多", "走了很多路", "运动很多", "运动了很多", "步数很多", "一直在外面走"
    ]
    // 只匹配“屏幕总时长”的自述；不把“没怎么碰手机”当成总屏幕少，
    // 因为同一天的电脑工作也会计入屏幕时长。
    private static let screenClaims = [
        "很少看屏幕", "屏幕时间很少", "今天几乎没看屏幕"
    ]
    private static let completionClaims = [
        "什么都没做", "一事无成", "什么都没完成", "什么也没做成"
    ]

    public static func observation(selfReport: String, facts: SelfReportFacts) -> String? {
        let text = selfReport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 完成事项最具体，优先于睡眠/屏幕/步数；一次只给一句。
        if let completed = facts.completedItems,
           completed >= completedContradictionCount,
           let claim = firstClaim(in: text, from: completionClaims, rejectsNegatedPrefix: true) {
            return "你写到“\(claim)”，而记录里有 \(completed) 项完成事项，可以放在一起看看。"
        }

        if let sleep = facts.sleepHours,
           sleep < sleepContradictionHours,
           let claim = firstClaim(in: text, from: sleepClaims) {
            return "你写到“\(claim)”，而当天睡眠记录是 \(oneDecimal(sleep)) 小时，可以放在一起看看。"
        }

        if let minutes = facts.screenMinutes,
           minutes >= screenContradictionMinutes,
           let claim = firstClaim(in: text, from: screenClaims, rejectsNegatedPrefix: true) {
            return "你写到“\(claim)”，而当天屏幕记录约 \(oneDecimal(Double(minutes) / 60)) 小时，可以放在一起看看。"
        }

        if let steps = facts.steps,
           steps < stepsContradictionCount,
           let claim = firstClaim(in: text, from: stepClaims) {
            return "你写到“\(claim)”，而当天步数记录是 \(steps) 步，可以放在一起看看。"
        }

        return nil
    }

    /// 找第一处出现的短语。正向短语要排除“没/不/未”前缀；负向短语要排除
    /// “不是/并非”这类把否定再否定的前缀。
    private static func firstClaim(
        in text: String,
        from claims: [String],
        rejectsNegatedPrefix: Bool = false
    ) -> String? {
        var candidates: [(phrase: String, offset: Int)] = []
        for phrase in claims {
            guard let range = text.range(of: phrase) else { continue }
            candidates.append((phrase, text.distance(from: text.startIndex, to: range.lowerBound)))
        }
        for candidate in candidates.sorted(by: { $0.offset == $1.offset ? $0.phrase.count > $1.phrase.count : $0.offset < $1.offset }) {
            let prefixStart = text.index(text.startIndex, offsetBy: max(0, candidate.offset - 6))
            let prefix = String(text[prefixStart..<text.index(text.startIndex, offsetBy: candidate.offset)])
            if rejectsNegatedPrefix {
                if prefix.contains("不是") || prefix.contains("并非") { continue }
            } else if ["没", "不", "未"].contains(where: { prefix.contains($0) }) {
                continue
            }
            return candidate.phrase
        }
        return nil
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
