import RiverDiaryCore
import Charts
import SwiftUI

struct InsightsView: View {
    @Environment(\.riverTheme) private var theme
    @EnvironmentObject private var store: DiaryStore
    @EnvironmentObject private var health: HealthKitStore
    @EnvironmentObject private var node: RiverNodeStore
    @Environment(\.dismiss) private var dismiss

    private var ratedEntries: [DiaryEntry] { store.entries.filter { $0.score != nil }.reversed() }
    private var averageScore: Double? {
        let scores = ratedEntries.compactMap(\.score)
        return scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
    }
    private var bestEntry: DiaryEntry? {
        ratedEntries.max { $0.score ?? 0 < $1.score ?? 0 }
    }
    private var hardestEntry: DiaryEntry? {
        ratedEntries.min { $0.score ?? 0 < $1.score ?? 0 }
    }
    private var weeklyChange: Double? {
        let scores = store.entries.compactMap(\.score)
        guard scores.count >= 4 else { return nil }

        let split = min(7, scores.count / 2)
        let current = scores.prefix(split)
        let previous = scores.dropFirst(split).prefix(split)
        guard !current.isEmpty, !previous.isEmpty else { return nil }

        return current.reduce(0, +) / Double(current.count)
            - previous.reduce(0, +) / Double(previous.count)
    }

    private var sleepMoodPairs: [(night: SleepNight, score: Double)] {
        health.nights.compactMap { night in
            // 未知睡眠不能当成 0 小时参与对照。
            guard night.hasAsleepSamples else { return nil }
            let key = DiaryEntry.dateFormatter.string(from: night.date)
            guard let entry = store.entries.first(where: { $0.date == key }),
                  let score = entry.score else { return nil }
            return (night, score)
        }
    }

    private var sleepContrast: (better: Double?, lower: Double?)? {
        let pairs = sleepMoodPairs.sorted { $0.score > $1.score }
        guard pairs.count >= 4 else { return nil }
        let split = pairs.count / 2
        let better = pairs.prefix(split).map(\.night.totalHours)
        let lower = pairs.suffix(split).map(\.night.totalHours)

        func average(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        return (average(better), average(lower))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !manualRatings.isEmpty { manualRatingCard }
                    if !store.entries.isEmpty {
                        Text("旧版记录与快照统计").font(.headline).foregroundStyle(theme.ink).frame(maxWidth: .infinity, alignment: .leading)
                        summaryRow
                        trendCard
                        qualityCard
                        sleepCard
                        distributionCard
                    } else if manualRatings.isEmpty {
                        ContentUnavailableView("还没有可回顾的评分", systemImage: "chart.xyaxis.line", description: Text("保存日记时可以选择给这一天评分；没有填写的日期保持未知。"))
                    }
                }
                .padding(16)
                .padding(.bottom, 20)
            }
            .background(theme.canvas)
            .navigationTitle("长期回顾")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭回顾") { dismiss() } } }
        }
    }

    private var manualRatings: [(day: String, score: Int)] {
        let legacyDays = Set(store.entries.map(\.date))
        return (node.database?.sharedUserRecords ?? []).compactMap { record in
            guard record.kind == .journalEntry, record.status == "current", let content = record.journalEntryContent,
                  !legacyDays.contains(content.dayKey), let value = content.moodScore, (0...100).contains(value) else { return nil }
            return (content.dayKey, value)
        }.sorted { $0.day < $1.day }
    }
    private var manualRatingCard: some View {
        let ratings = manualRatings
        let recent = Array(ratings.suffix(12))
        return RiverIOSPanel {
            VStack(alignment: .leading, spacing: 14) {
                Text("你填写的日记评分").font(.headline).accessibilityIdentifier("river.insights.manual")
                Text("\(ratings.count) 个评分日 · 未评分的日期不计入统计").font(.callout).foregroundStyle(theme.secondaryInk)
                if let last = ratings.last {
                    LabeledContent("最近一次", value: "\(last.score) / 100")
                    Text(last.day).font(.footnote.monospacedDigit()).foregroundStyle(theme.secondaryInk)
                }
                if recent.count > 1 {
                    Chart(recent, id: \.day) { item in
                        BarMark(x: .value("日期", String(item.day.suffix(5))), y: .value("评分", item.score))
                            .foregroundStyle(theme.accentText)
                    }.chartYScale(domain: 0...100).frame(height: 180)
                        .accessibilityLabel("最近十二个评分日")
                }
                Text("只展示你实际填写的数值，不推断未记录的心情。").font(.footnote).foregroundStyle(theme.secondaryInk)
            }
        }
    }

    private var qualityStatusColor: Color {
        switch store.data?.dataQuality?.status {
        case "good": return theme.success
        case "warning": return theme.warning
        case "needs_attention": return theme.danger
        default: return theme.secondaryInk
        }
    }

    private var qualityCard: some View {
        RiverIOSPanel {
            VStack(alignment: .leading, spacing: 12) {
                let quality = store.data?.dataQuality
                RiverIOSSectionHeading(title: "数据体检", detail: "补齐关键信息，回忆更可靠")
                HStack {
                    Text(quality?.status == "good" ? "健康" : quality?.status == "warning" ? "可优化" : quality == nil ? "旧版快照" : "需补录")
                        .font(.headline)
                        .foregroundStyle(qualityStatusColor)
                    Spacer()
                    if let count = quality?.criticalCount {
                        Text("关键缺失 \(count)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(theme.secondaryInk)
                    }
                }

                qualityRow("待评分", quality?.issues?.missingScores?.count)
                qualityRow("缺概览", quality?.issues?.missingOverview?.count)
                qualityRow("缺计划", quality?.issues?.missingPlan?.count)

                if quality?.criticalCount ?? 0 > 0 {
                    Text("先补心情和日记概览；计划可以之后再补。")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryInk)
                } else {
                    Text("关键记录完整，继续保持这个节奏。")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryInk)
                }
            }
        }
    }

    private func qualityRow(_ title: String, _ count: Int?) -> some View {
        HStack {
            Text(title)
                .font(.footnote)
                .foregroundStyle(theme.secondaryInk)
            Spacer()
            Text("\(count ?? 0)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle((count ?? 0) > 0 ? theme.warning : theme.secondaryInk)
        }
        .accessibilityElement(children: .combine)
    }

    private var summaryRow: some View {
        HStack(spacing: 12) {
            statCard("平均", averageScore.map { String(format: "%.1f", $0) } ?? "—", "circle.dashed.inset.filled")
            statCard("最高", bestEntry?.score.map { String(format: "%.0f", $0) } ?? "—", "arrow.up.forward")
            statCard("最低", hardestEntry?.score.map { String(format: "%.0f", $0) } ?? "—", "arrow.down.forward")
        }
    }

    private var trendCard: some View {
        RiverIOSPanel {
            VStack(alignment: .leading, spacing: 16) {
                RiverIOSSectionHeading(title: "情绪趋势", detail: "近 \(ratedEntries.count) 天")
                if let change = weeklyChange {
                    Label(
                        change >= 0 ? "近期较此前提升 \(String(format: "%.1f", change)) 分" : "近期较此前回落 \(String(format: "%.1f", abs(change))) 分",
                        systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right"
                    )
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(change >= 0 ? theme.success : theme.warning)
                }
                Chart(ratedEntries) { entry in
                    LineMark(
                        x: .value("日期", entry.entryDate),
                        y: .value("心情", entry.score ?? 0)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(theme.accentText)

                    AreaMark(
                        x: .value("日期", entry.entryDate),
                        y: .value("心情", entry.score ?? 0)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(theme.accent.opacity(0.12))
                }
                .chartYScale(domain: 0...100)
                .frame(height: 200)
            }
        }
    }

    private var distributionCard: some View {
        RiverIOSPanel {
            VStack(alignment: .leading, spacing: 16) {
                RiverIOSSectionHeading(title: "阶段分布", detail: "全部记录")
                let counts = Dictionary(grouping: store.entries, by: \.stageLabel).mapValues(\.count)
                let maxCount = max(counts.values.max() ?? 1, 1)

                ForEach(Scoring.stages, id: \.label) { stage in
                    let count = counts[stage.label] ?? 0
                    HStack {
                        Text(stage.label).font(.footnote).frame(width: 38, alignment: .leading)
                        ProgressView(value: Double(count), total: Double(maxCount))
                            .tint(stage.swiftColor)
                        Text("\(count)")
                            .font(.footnote)
                            .monospacedDigit()
                            .frame(width: 24)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var sleepCard: some View {
        RiverIOSPanel {
            VStack(alignment: .leading, spacing: 14) {
                RiverIOSSectionHeading(title: "睡眠与情绪", detail: health.isAuthorized ? "最近 \(sleepMoodPairs.count) 晚" : "未连接")

                if let contrast = sleepContrast, let better = contrast.better, let lower = contrast.lower {
                    Label(
                        "心情较好时段平均 \(String(format: "%.1f", better)) 小时，较低时段 \(String(format: "%.1f", lower)) 小时",
                        systemImage: "bed.double"
                    )
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(theme.secondaryInk)
                } else {
                    Text(health.isAuthorized ? "再积累几天匹配的睡眠与心情数据后，这里会显示对照。" : "连接 Apple 健康后，可查看睡眠时长与情绪的对照。")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryInk)
                }

                ForEach(sleepMoodPairs.prefix(7), id: \.night.id) { pair in
                    HStack {
                        Text(pair.night.date, style: .date)
                            .font(.footnote)
                        Spacer()
                        Text(String(format: "%.1f 小时", pair.night.totalHours))
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                        Text("心情 \(Int(pair.score.rounded()))")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryInk)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func statCard(_ title: String, _ value: String, _ icon: String) -> some View {
        RiverIOSPanel {
            VStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(theme.accentText)
                Text(value).font(.title2.weight(.bold))
                Text(title).font(.caption).foregroundStyle(theme.secondaryInk)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }
}
