import Foundation

/// 窗口标题的周期重采样。
///
/// 原来标题只在**应用切换的那一瞬间**读一次。实测本机 2297 条片段里只有 1 条带标题：
/// 切换的那一刻目标应用往往还没有窗口（辅助功能读不到），于是这一段永远没有标题——
/// 而"缺少窗口标题"正是待确认队列的判据之一，判据因此退化成恒真。
///
/// 这里只放判定，不碰 AX、不碰存储：决策是纯的，"什么时候读"由 `ActivityStore` 管。
/// 三条规则：
///
/// 1. **读不到就什么都不做**。AX 读取失败是常态，一次失败绝不能把已有的标题擦掉。
/// 2. **片段还没有标题 → 补上**。这是"切换瞬间读不到"的正解。
/// 3. **标题稳定地换了 → 从第一次看到它的那一刻切开**。同一应用里的两个窗口
///    是两件事：合并成一段，行上的标题对其中一半时间就是假的。要求连续两次
///    采样都读到同一个新标题才认账（25 秒一次，也就是 50 秒），因为标题会因为
///    一条通知、一个未读数抖动——「(3) Slack」「(4) Slack」不该把一段阅读切成渣。
enum WindowTitleSampling {
    /// 采样间隔。
    static let interval: TimeInterval = 25
    /// 新标题要连续被看到这么久才认账。两次采样。
    static let confirmationInterval: TimeInterval = 50

    /// 疑似新标题：第一次看到它的时刻。切开时用这个时刻，而不是确认的时刻——
    /// 标题实际是什么时候换的我们不知道，但不会晚于第一次看到它。
    struct Pending: Equatable {
        let title: String
        let since: Date
    }

    enum Action: Equatable {
        case ignore
        /// 片段还没有标题，把这一次读到的东西挂上去。
        case adopt(String)
        /// 标题真的换了：在 `at` 处把当前片段截断，从那里开一段带新标题的。
        case split(at: Date, title: String)
    }

    struct Decision: Equatable {
        let action: Action
        /// 下一次比较要带的"疑似新标题"。非空不代表已经认账。
        let pending: Pending?
    }

    static func decide(
        currentTitle: String?,
        pending: Pending?,
        sampled raw: String?,
        now: Date
    ) -> Decision {
        guard let sampled = normalize(raw) else {
            return Decision(action: .ignore, pending: nil)
        }
        guard let current = normalize(currentTitle) else {
            return Decision(action: .adopt(sampled), pending: nil)
        }
        if current == sampled {
            // 回到原样：可能是一闪而过的通知标题，也可能只是之前那次读失败。
            return Decision(action: .ignore, pending: nil)
        }
        if let pending, pending.title == sampled {
            if now.timeIntervalSince(pending.since) >= confirmationInterval {
                return Decision(action: .split(at: pending.since, title: sampled), pending: nil)
            }
            return Decision(action: .ignore, pending: pending)
        }
        return Decision(action: .ignore, pending: Pending(title: sampled, since: now))
    }

    /// 归一化：去掉首尾空白、折叠内部连续空白、剥掉开头那个未读计数。
    /// 归一化之后是空串的标题（纯空格、单个符号）等于没读到。
    static func normalize(_ title: String?) -> String? {
        guard var text = title else { return nil }
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripLeadingBadge(text)
        guard text.count >= 2 else { return nil }
        return text
    }

    /// 「(3) 收件箱」「(12)Slack」这种开头的未读数不是标题的一部分。
    private static func stripLeadingBadge(_ text: String) -> String {
        guard text.hasPrefix("(") else { return text }
        guard let close = text.firstIndex(of: ")") else { return text }
        let digits = text[text.index(after: text.startIndex)..<close]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), digits.count <= 3 else { return text }
        return String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
    }
}
