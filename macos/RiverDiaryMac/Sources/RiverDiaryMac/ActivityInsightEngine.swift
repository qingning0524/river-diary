import Foundation

struct ActivityCorrelation: Identifiable, Hashable {
    var id: String { title }
    var title: String
    var sampleCount: Int
    var strength: Int
    var directionLabel: String
    var detail: String
    var icon: String
    var colorHex: String

    var isUsable: Bool { sampleCount >= 4 && abs(strength) >= 18 }
}

enum ActivityCorrelationEngine {
    static func insights(dayStats: [FusedDayStats], entries: [DiaryEntry]) -> [ActivityCorrelation] {
        let entriesByDate = Dictionary(uniqueKeysWithValues: entries.map { ($0.date, $0) })
        let paired = dayStats.compactMap { day -> (day: FusedDayStats, entry: DiaryEntry)? in
            guard let entry = entriesByDate[day.dateKey] else { return nil }
            return (day, entry)
        }

        var results: [ActivityCorrelation] = []

        let screenMood = pairs(paired.filter { $0.day.pipelineAvailable }) {
            ($0.pipelineTotal, Double($1.mood))
        }
        results.append(
            correlation(
                title: "屏幕时间 × 心情",
                pairs: screenMood,
                icon: "display",
                colorHex: "#7787FF",
                positiveText: "屏幕时间更高的日子，心情评分往往也更高。",
                negativeText: "屏幕时间更高的日子，心情评分往往更低。",
                neutralText: "屏幕时间与心情目前没有稳定关联。"
            )
        )

        let stepsMood = pairs(paired.filter { $0.day.health?.steps != nil }) {
            (Double($0.health?.steps ?? 0), Double($1.mood))
        }
        results.append(
            correlation(
                title: "步数 × 心情",
                pairs: stepsMood,
                icon: "figure.walk",
                colorHex: "#2C8158",
                positiveText: "步数更多的日子，心情评分往往更高。",
                negativeText: "步数更多的日子，心情评分反而更低。",
                neutralText: "步数与心情目前没有稳定关联。"
            )
        )

        let focusOutput = pairs(paired.filter { $0.day.liveTotal > 0 }) {
            ($0.focusTotal, Double($1.output))
        }
        results.append(
            correlation(
                title: "实时专注 × 产出",
                pairs: focusOutput,
                icon: "target",
                colorHex: "#4FB6A9",
                positiveText: "专注片段更多的日子，产出评分通常更高。",
                negativeText: "专注片段更多的日子，产出评分反而更低。",
                neutralText: "实时专注与产出评分还没有稳定关联。"
            )
        )

        let entertainmentMood = pairs(paired.filter { !$0.day.appUsage.isEmpty }) {
            (
                $0.categoryUsage.first { $0.category == "娱乐" }?.duration ?? 0,
                Double($1.mood)
            )
        }
        results.append(
            correlation(
                title: "娱乐时长 × 心情",
                pairs: entertainmentMood,
                icon: "play.tv.fill",
                colorHex: "#F2788D",
                positiveText: "娱乐时间更多的日子，心情评分往往更高。",
                negativeText: "娱乐时间更高的日子，心情评分往往更低。",
                neutralText: "娱乐时长与心情目前没有稳定关联。"
            )
        )

        return results
    }

    private static func pairs(
        _ paired: [(day: FusedDayStats, entry: DiaryEntry)],
        transform: (FusedDayStats, DiaryEntry) -> (Double, Double)
    ) -> [(Double, Double)] {
        paired.map(transform).filter { first, second in
            first.isFinite && second.isFinite
        }
    }

    private static func correlation(
        title: String,
        pairs: [(Double, Double)],
        icon: String,
        colorHex: String,
        positiveText: String,
        negativeText: String,
        neutralText: String
    ) -> ActivityCorrelation {
        guard pairs.count >= 4 else {
            return ActivityCorrelation(
                title: title,
                sampleCount: pairs.count,
                strength: 0,
                directionLabel: "样本不足",
                detail: "至少需要 4 天同时有这两类数据，才会给出趋势线索。",
                icon: icon,
                colorHex: colorHex
            )
        }

        let coefficient = pearson(pairs)
        let strength = Int((abs(coefficient) * 100).rounded())
        let label: String
        if coefficient > 0.25 { label = "同向上升" }
        else if coefficient < -0.25 { label = "反向变化" }
        else { label = "关联较弱" }

        let detail: String
        if coefficient > 0.25 { detail = positiveText }
        else if coefficient < -0.25 { detail = negativeText }
        else { detail = neutralText }

        return ActivityCorrelation(
            title: title,
            sampleCount: pairs.count,
            strength: strength,
            directionLabel: label,
            detail: detail,
            icon: icon,
            colorHex: colorHex
        )
    }

    private static func pearson(_ values: [(Double, Double)]) -> Double {
        guard !values.isEmpty else { return 0 }
        let count = Double(values.count)
        let meanX = values.reduce(0) { $0 + $1.0 } / count
        let meanY = values.reduce(0) { $0 + $1.1 } / count

        var numerator = 0.0
        var sumX = 0.0
        var sumY = 0.0

        for (x, y) in values {
            let dx = x - meanX
            let dy = y - meanY
            numerator += dx * dy
            sumX += dx * dx
            sumY += dy * dy
        }

        let denominator = (sumX * sumY).squareRoot()
        guard denominator > 0 else { return 0 }
        return max(-1, min(1, numerator / denominator))
    }
}
