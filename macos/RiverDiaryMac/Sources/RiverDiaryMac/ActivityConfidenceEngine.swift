import Foundation

struct ActivityConfidenceFactor: Identifiable, Hashable {
    var title: String
    var value: Int
    var maximum: Int
    var detail: String

    var id: String { title }
    var ratio: Double { maximum > 0 ? Double(value) / Double(maximum) : 0 }
    var scoreText: String { "\(value)/\(maximum)" }
}

enum ActivityConfidenceEngine {
    static let pipelineMaximum = 50
    static let liveMaximum = 25
    static let consistencyMaximum = 25

    static func day(entry: DiaryEntry?, liveSessions: [ActivitySession]) -> (score: Int, factors: [ActivityConfidenceFactor]) {
        let live = liveSessions.sorted { $0.start < $1.start }
        let pipelineTotal = Double(entry?.screenMinutes ?? 0) * 60
        let pipelineApps = entry?.screenApps ?? []
        let pipelineAppMinutes = pipelineApps.reduce(0) { $0 + ($1.minutes ?? 0) }
        let liveTotal = live.reduce(0) { $0 + $1.duration }
        let longestLive = live.map(\.duration).max() ?? 0

        // 项目数据最高 50 分：总量是主干，应用明细补足分布，浏览与运动补充证据类型。
        let screenScore = confidenceValue(
            Double(pipelineTotal),
            tiers: [0, 15 * 60, 60 * 60, 3 * 3600, 6 * 3600],
            points: [0, 6, 13, 19, 22]
        )
        let appDetailScore = pipelineApps.isEmpty
            ? 0
            : min(14, 6 + Int((Double(pipelineApps.count) / 3.0 * 8).rounded()))
        let appAgreementScore = pipelineApps.isEmpty || pipelineTotal <= 0
            ? 0
            : abs(Double(pipelineAppMinutes) * 60 - pipelineTotal) <= 900 ? 4 : 2
        let browseScore = (entry?.browseSites ?? []).isEmpty ? 0 : 5
        let healthScore = entry?.hasMovementSignal == true ? 5 : 0
        _ = screenScore + appDetailScore + appAgreementScore + browseScore + healthScore

        // 实时足迹最高 25 分：奖励有效覆盖，而不是只看“有没有一条记录”。
        let liveVolumeScore = confidenceValue(
            liveTotal,
            tiers: [0, 5 * 60, 30 * 60, 2 * 3600, 5 * 3600],
            points: [0, 3, 8, 12, 15]
        )
        let liveBreadthScore = min(3, Set(live.map(\.dayKey)).count)
        let liveQualityScore = live.isEmpty
            ? 0
            : min(7, 1 + (longestLive >= 5 * 60 ? 3 : 0) + (live.count >= 4 ? 3 : 0))
        let liveScore = liveVolumeScore + liveBreadthScore + liveQualityScore

        // 一致性最高 25 分。双方都有信号时按总时长差异评分；单源只给中性的基础分。
        let consistencyScore: Int
        let consistencyDetail: String
        if pipelineTotal > 0 && liveTotal > 0 {
            let differenceRatio = abs(pipelineTotal - liveTotal) / max(pipelineTotal, liveTotal)
            consistencyScore = max(4, min(25, Int((25 * (1.0 - differenceRatio * 0.85)).rounded())))
            consistencyDetail = "双源总时长差异 \(Int(differenceRatio * 100))%"
        } else if pipelineTotal > 0 || liveTotal > 0 {
            consistencyScore = 12
            consistencyDetail = pipelineTotal > 0 ? "只有项目数据可交叉验证" : "只有 macOS 实时可交叉验证"
        } else {
            consistencyScore = 0
            consistencyDetail = "当日没有可交叉验证的活动时长"
        }

        let factors: [ActivityConfidenceFactor] = [
            ActivityConfidenceFactor(
                title: "每日总量",
                value: screenScore,
                maximum: 22,
                detail: pipelineTotal > 0 ? "项目数据记录 \(ActivityFormatter.time(pipelineTotal))。" : "缺少项目数据的屏幕总量。"
            ),
            ActivityConfidenceFactor(
                title: "应用明细",
                value: appDetailScore + appAgreementScore,
                maximum: 18,
                detail: pipelineApps.isEmpty
                    ? "没有应用级明细。"
                    : "\(pipelineApps.count) 个应用；内部汇总\(appAgreementScore >= 4 ? "一致" : "略有偏差")。"
            ),
            ActivityConfidenceFactor(
                title: "浏览与运动",
                value: browseScore + healthScore,
                maximum: 10,
                detail: "\(browseScore > 0 ? "有浏览足迹" : "无浏览足迹")，\(healthScore > 0 ? "有运动信号" : "无运动信号")。"
            ),
            ActivityConfidenceFactor(
                title: "实时覆盖",
                value: liveScore,
                maximum: 25,
                detail: live.isEmpty
                    ? "没有已保存的实时片段。"
                    : "\(live.count) 段、最长 \(ActivityFormatter.time(longestLive))。"
            ),
            ActivityConfidenceFactor(
                title: "两份记录一致性",
                value: consistencyScore,
                maximum: 25,
                detail: consistencyDetail
            )
        ]

        let total = factors.reduce(0) { $0 + $1.value }
        return (min(100, total), factors)
    }

    static func range(dayStats: [FusedDayStats]) -> (score: Int, factors: [ActivityConfidenceFactor]) {
        let weightedDays = dayStats.filter { $0.confidence > 0 }
        guard !weightedDays.isEmpty else {
            return (0, averagedFactors(dayStats.flatMap(\.confidenceFactors), dayCount: max(1, dayStats.count)))
        }

        // 少量证据不应与高覆盖天数获得同样权重；但也不会让一分钟片段拥有 92 分。
        var totalWeight = 0.0
        var weightedScore = 0.0
        for day in weightedDays {
            let evidence = day.pipelineTotal + day.liveTotal
            let weight = 1.0 + min(2.0, evidence / (4 * 3600))
            totalWeight += weight
            weightedScore += Double(day.confidence) * weight
        }

        let coveragePenalty = Double(weightedDays.count) / Double(max(1, dayStats.count))
        let score = Int((weightedScore / max(1, totalWeight) * coveragePenalty).rounded())
        return (min(100, max(0, score)), averagedFactors(dayStats.flatMap(\.confidenceFactors), dayCount: max(1, dayStats.count)))
    }

    static func averagedFactors(_ factors: [ActivityConfidenceFactor], dayCount: Int) -> [ActivityConfidenceFactor] {
        let titles = ["每日总量", "应用明细", "浏览与运动", "实时覆盖", "两份记录一致性"]
        return titles.compactMap { title in
            let group = factors.filter { $0.title == title }
            guard let maximum = group.first?.maximum, maximum > 0 else { return nil }
            let value = Int((Double(group.reduce(0) { $0 + $1.value }) / Double(max(1, dayCount))).rounded())
            let details = Array(Set(group.map(\.detail))).sorted().prefix(2).joined(separator: "；")
            return ActivityConfidenceFactor(
                title: title,
                value: min(maximum, max(0, value)),
                maximum: maximum,
                detail: details.isEmpty ? "当前范围无样本。" : details
            )
        }
    }

    private static func confidenceValue(_ value: Double, tiers: [Double], points: [Int]) -> Int {
        guard !tiers.isEmpty, !points.isEmpty, value > 0 else { return 0 }
        var score = 0
        for (index, tier) in tiers.enumerated() where value >= tier {
            score = points[min(index, points.count - 1)]
        }
        return score
    }
}
