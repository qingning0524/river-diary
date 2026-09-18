import SwiftUI

// Pure rhythm/letter models. Extracted from the retired Rhythm view so that
// existing model tests keep running; these are data + deterministic math only.

struct LifeSegment: Identifiable {
    var id: String { title }
    var title: String
    var totalDuration: TimeInterval
    var appSummary: String
    var color: Color
    var durationFraction: CGFloat

    static func make(from sessions: [ActivitySession]) -> [LifeSegment] {
        let definitions: [(String, Range<Int>, Color)] = [
            ("清晨", 5..<12, Color(hex: "#FFB74D")),
            ("午后", 12..<18, Color(hex: "#42A5F5")),
            ("夜晚", 18..<24, Color(hex: "#7E57C2")),
            ("深夜", 0..<5, Color(hex: "#78909C"))
        ]

        let maxDuration = definitions.map { definition in
            sessions.filter { definition.1.contains($0.hour) }.reduce(0.0) { $0 + $1.duration }
        }.max() ?? 0

        return definitions.compactMap { definition in
            let group = sessions.filter { definition.1.contains($0.hour) }
            let total = group.reduce(0.0) { $0 + $1.duration }
            guard total > 0 else { return nil }
            let topApps = Dictionary(grouping: group, by: { $0.appName })
                .mapValues { $0.reduce(0.0) { $0 + $1.duration } }
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { "\($0.key)" }
            return LifeSegment(
                title: definition.0,
                totalDuration: total,
                appSummary: topApps.isEmpty ? "应用未识别" : topApps.joined(separator: " · "),
                color: definition.2,
                durationFraction: maxDuration > 0 ? CGFloat(total / maxDuration) : 0
            )
        }
    }
}

struct RiverLetter {
    var title: String
    var body: String

    static func make(entries: [DiaryEntry], captures: [QuickCapture], sessions: [ActivitySession], days: Int) -> RiverLetter? {
        guard days >= 30, !entries.isEmpty else { return nil }
        let scored = entries.filter { $0.score != nil || $0.metrics?.overall != nil }
        let scores = scored.map { $0.metrics?.overall ?? $0.score ?? 0 }
        let average = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
        let best = scored.max { ($0.metrics?.overall ?? $0.score ?? 0) < ($1.metrics?.overall ?? $0.score ?? 0) }
        let quiet = scored.min { ($0.metrics?.overall ?? $0.score ?? 0) < ($1.metrics?.overall ?? $1.score ?? 0) }
        let topApp = Dictionary(grouping: sessions, by: \.appName)
            .mapValues { $0.reduce(0.0) { $0 + $1.duration } }
            .max { $0.value < $1.value }?.key

        let opening = "我注意到这 \(days) 天里，你有 \(entries.count) 天留下了痕迹。平均状态在 \(Int(average)) 附近；这不是评分，只是节律的一个中点。"
        let bestText = best.map { "最亮的一天落在 \($0.shortDate)，它也许不完美，但确实在流动。" } ?? ""
        let quietText = quiet.map { "安静一点的 \($0.shortDate) 也被记住了。它不需要被修好，只是那段河面更平。" } ?? ""
        let activityText = topApp.map { "你有很多时间在和「\($0)」相处，它参与了这段日子的形状。" } ?? "应用足迹还不够完整，但从评分和快记里，仍然能看见生活的轮廓。"
        let captureText = captures.isEmpty ? "有时候没有留下更多字句，也是一种安静。" : "你留下了 \(captures.count) 条快记，它们像水面上的小光点。"
        let ending = "如果你想，可以把某一天再打开一次；也可以什么都不做，让这段日子先静静沉下来。"

        return RiverLetter(
            title: "这段时间的河流",
            body: [opening, bestText, quietText, activityText, captureText, ending]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        )
    }
}

enum Pearson {
    static func compute(_ pairs: [(Double, Double)]) -> Double {
        let valid = pairs.filter { $0.0.isFinite && $0.1.isFinite }
        guard valid.count >= 3 else { return 0 }
        let xs = valid.map(\.0)
        let ys = valid.map(\.1)
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        let numerator = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let dx = sqrt(xs.reduce(0) { $0 + pow($1 - mx, 2) })
        let dy = sqrt(ys.reduce(0) { $0 + pow($1 - my, 2) })
        guard dx > 0, dy > 0 else { return 0 }
        return numerator / (dx * dy)
    }
}
