import Foundation

/// 证据引用的唯一命名空间。
///
/// 产品主张是"每条结论都能回到原始记录"，但此前 `AnalysisRun.evidenceIDs`
/// 被塞进的是 `sessions.map(\.id)`——只有实时片段，日记、快记、健康一条都没有；
/// 而日记这类记录本身没有 UUID，无法用 `[UUID]` 表达。这里给出一个跨来源统一的
/// 字符串引用形式，并保证**只有真的能在本机查到的东西**才会成为引用。
///
/// 形如：
/// - `raw:<uuid>`      实时片段 / 原始事件（V2 `raw_events`）
/// - `diary:<yyyy-MM-dd>` 日记（按天唯一）
/// - `capture:<uuid>`  快记
/// - `health:<yyyy-MM-dd>` 健康快照（按天唯一）
/// - `episode:<uuid>`  融合片段
enum EvidenceReference {
    enum Kind: String, CaseIterable {
        case raw
        case diary
        case capture
        case health
        case episode

        var label: String {
            switch self {
            case .raw: "实时片段"
            case .diary: "日记"
            case .capture: "快记"
            case .health: "健康"
            case .episode: "时间段"
            }
        }
    }

    struct Parsed: Hashable {
        var kind: Kind
        var value: String
    }

    /// 解析单个引用。无法识别的形式返回 nil —— 调用方必须丢弃它，
    /// 而不是把模型编造出来的东西当成依据存下来。
    static func parse(_ raw: String) -> Parsed? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: ":") else { return nil }
        let prefix = String(trimmed[trimmed.startIndex..<separator])
        let value = String(trimmed[trimmed.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let kind = Kind(rawValue: prefix) else { return nil }

        switch kind {
        case .raw, .capture, .episode:
            // UUID 类引用必须真的是 UUID。日记/健康是日期键。
            guard UUID(uuidString: value) != nil else { return nil }
        case .diary, .health:
            guard isDayKey(value) else { return nil }
        }
        return Parsed(kind: kind, value: value)
    }

    /// 把一个证据集合裁剪成"可核对"的引用列表：解析失败、或不在
    /// `allowed` 白名单里的引用一律丢弃，并返回被丢弃的数量供 UI 提示。
    static func sanitize(
        _ candidates: [String],
        allowed: Set<String>
    ) -> (kept: [String], dropped: Int) {
        var kept: [String] = []
        var seen = Set<String>()
        var dropped = 0
        for candidate in candidates {
            guard let parsed = parse(candidate) else {
                dropped += 1
                continue
            }
            let normalized = "\(parsed.kind.rawValue):\(parsed.value)"
            guard allowed.contains(normalized) else {
                dropped += 1
                continue
            }
            guard seen.insert(normalized).inserted else { continue }
            kept.append(normalized)
        }
        return (kept, dropped)
    }

    /// 由本机记录构造白名单。只有传进来的记录才会被认作有效依据。
    static func allowedSet(
        sessionIDs: [UUID] = [],
        diaryDays: [String] = [],
        captureIDs: [UUID] = [],
        healthDays: [String] = [],
        episodeIDs: [UUID] = []
    ) -> Set<String> {
        var allowed = Set<String>()
        sessionIDs.forEach { allowed.insert("raw:\($0.uuidString)") }
        captureIDs.forEach { allowed.insert("capture:\($0.uuidString)") }
        episodeIDs.forEach { allowed.insert("episode:\($0.uuidString)") }
        diaryDays.forEach { allowed.insert("diary:\($0)") }
        healthDays.forEach { allowed.insert("health:\($0)") }
        return allowed
    }

    /// 把一段自由文本里出现的引用抽出来（模型有时会把依据写在正文里）。
    static func extract(from text: String) -> [String] {
        let pattern = "\\b(raw|capture|episode):[0-9a-fA-F-]{36}\\b|\\b(diary|health):\\d{4}-\\d{2}-\\d{2}\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return parse(String(text[swiftRange])).map { "\($0.kind.rawValue):\($0.value)" }
        }
    }

    /// `yyyy-MM-dd` 的宽松校验：只查形状与数值范围，不做日历合法性判断。
    static func isDayKey(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
        return (1...12).contains(month) && (1...31).contains(day)
    }
}
