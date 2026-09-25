import SwiftUI
import Charts

struct ProgressWorkspaceView: View {
    @Environment(\.riverDensity) private var density
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    let selectedDate: Date

    @State private var dayCount = 30

    private var calendar: Calendar { .current }
    private var comparisonEndDate: Date {
        ProgressAnchor.completedEndDate(selectedDate: selectedDate, calendar: calendar)
    }
    private var currentWindow: ProgressWindow {
        ProgressWindow(dayCount: dayCount, endingOn: comparisonEndDate, calendar: calendar)
    }
    private var previousWindow: ProgressWindow { currentWindow.preceding }

    private func summary(_ stats: FusedRangeStats) -> ProgressPeriodSummary {
        ProgressPeriodSummary(
            stats: stats,
            entries: store.entries,
            captures: store.quickCaptures,
            dailyGoals: store.dailyGoals
        )
    }

    var body: some View {
        let currentStats = activity.summary(entries: store.entries, days: dayCount, around: currentWindow.end)
        let previousStats = activity.summary(entries: store.entries, days: dayCount, around: previousWindow.end)
        let current = summary(currentStats)
        let previous = summary(previousStats)
        let currentTrend = trendPoints(currentStats, window: currentWindow, isCurrent: true)
        let previousTrend = trendPoints(previousStats, window: previousWindow, isCurrent: false)

        RiverPage(spacing: AppSpacing.sectionGap) {
            PageHeader("进展", context: "与上一个同长度周期对照 · 截止\(dateLabel)") {
                periodPicker
            }
            .riverAppear(index: 0)

            comparisonHeader
                .riverAppear(index: 1)
            ProgressFocusTrendChart(
                current: currentTrend,
                previous: previousTrend,
                dayCount: dayCount,
                currentCoverage: current.recordedDays,
                previousCoverage: previous.recordedDays
            )
            .riverAppear(index: 2)

            comparisonTable(current: current, previous: previous)
                .riverAppear(index: 3)

            RiverPanel(title: "如何阅读这组对照", systemImage: "questionmark.circle", accent: AppTheme.neutral) {
                SettingsFootnote(text: "若所选日期是今天，当前周期截至昨天，避免拿未完成的一天与完整周期比较。差异只描述已采集的记录，不代表效率、因果或个人价值；缺失的评分、步数和活动不会按零补齐。")
            }
            .riverAppear(index: 4)
        }
    }

    private var periodPicker: some View {
        RiverSegmentedPicker(
            title: "进展对照周期",
            selection: $dayCount,
            options: [30, 90, 365],
            label: { "\($0) 天" }
        )
    }

    private var comparisonHeader: some View {
        RiverPanel(title: "同长度周期", systemImage: "calendar.badge.clock", accent: AppTheme.accent, tint: AppTheme.accent) {
            HStack(alignment: .top, spacing: density.spacing(AppSpacing.lg)) {
                periodLabel("当前周期", window: currentWindow)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.tertiaryInk)
                    .padding(.top, density.spacing(AppSpacing.panelPadding))
                periodLabel("上一周期", window: previousWindow)
            }
        }
    }

    private func periodLabel(_ title: String, window: ProgressWindow) -> some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xs)) {
            RiverGroupLabel(text: title)
            Text(periodRangeLabel(window))
                .font(AppTypography.numeric())
                .foregroundStyle(Color.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dateLabel: String { comparisonEndDate.formatted(.dateTime.year().month().day()) }

    private func periodRangeLabel(_ window: ProgressWindow) -> String {
        if window.spansCalendarYears {
            return "\(window.start.formatted(.dateTime.year().month().day())) – \(window.end.formatted(.dateTime.year().month().day()))"
        }
        return "\(window.start.formatted(.dateTime.month().day())) – \(window.end.formatted(.dateTime.month().day()))"
    }

    private func durationChange(_ current: TimeInterval?, _ previous: TimeInterval?) -> String {
        guard let current, let previous else { return "记录不足，无法比较" }
        let delta = current - previous
        let sign = delta > 0 ? "+" : delta < 0 ? "−" : "±"
        return "较前期 \(sign)\(ActivityFormatter.time(abs(delta)))"
    }

    private func countChange(_ current: Int, _ previous: Int) -> String {
        let delta = current - previous
        let sign = delta > 0 ? "+" : delta < 0 ? "−" : "±"
        return "较前期 \(sign)\(abs(delta)) 天"
    }

    private func scoreChange(_ current: Double?, _ previous: Double?, unit: String = "分") -> String {
        guard let current, let previous else { return "记录不足，无法比较" }
        let delta = Int((current - previous).rounded())
        let sign = delta > 0 ? "+" : delta < 0 ? "−" : "±"
        return "较前期 \(sign)\(abs(delta)) \(unit)"
    }

    private func goalSummary(_ summary: ProgressPeriodSummary) -> String {
        summary.goalDays > 0 ? "\(summary.completedGoalDays) / \(summary.goalDays) 天" : "未知"
    }

    private func goalCompletionChange(_ current: ProgressPeriodSummary, _ previous: ProgressPeriodSummary) -> String {
        guard current.goalDays > 0, previous.goalDays > 0 else { return "目标记录不足，无法比较" }
        let currentRate = Double(current.completedGoalDays) / Double(current.goalDays)
        let previousRate = Double(previous.completedGoalDays) / Double(previous.goalDays)
        let delta = Int(((currentRate - previousRate) * 100).rounded())
        let sign = delta > 0 ? "+" : delta < 0 ? "−" : "±"
        return "较前期 \(sign)\(abs(delta)) 个百分点"
    }

    private func focusCoverage(_ summary: ProgressPeriodSummary) -> String {
        guard summary.recordedDays > 0 else { return "没有可比较的实时足迹" }
        let unclassified = summary.unclassifiedDuration.map(ActivityFormatter.time) ?? "未知"
        return "实时足迹覆盖 \(summary.recordedDays) 天 · 其他类别 \(unclassified)"
    }

    private func trendPoints(
        _ stats: FusedRangeStats,
        window: ProgressWindow,
        isCurrent: Bool
    ) -> [ProgressTrendPoint] {
        var points: [ProgressTrendPoint] = []
        var previousIndex: Int?
        var segment = 0
        let start = calendar.startOfDay(for: window.start)

        for day in stats.dayStats.sorted(by: { $0.dateKey < $1.dateKey }) {
            guard let date = DiaryEntry.dateFormatter.date(from: day.dateKey) else { continue }
            let dayIndex = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? 0
            guard day.liveTotal > 0 else {
                previousIndex = nil
                continue
            }
            if previousIndex == nil || previousIndex! + 1 != dayIndex { segment += 1 }
            points.append(ProgressTrendPoint(
                dayIndex: dayIndex,
                hours: day.focusTotal / 3600,
                isCurrent: isCurrent,
                segment: segment
            ))
            previousIndex = dayIndex
        }
        return points
    }

    private func comparisonTable(current: ProgressPeriodSummary, previous: ProgressPeriodSummary) -> some View {
        let rows = [
            ProgressMetricComparison(
                title: "工作与学习",
                current: current.focusDuration.map(ActivityFormatter.time) ?? "未知",
                previous: previous.focusDuration.map(ActivityFormatter.time) ?? "未知",
                change: durationChange(current.focusDuration, previous.focusDuration),
                coverage: focusCoverage(current),
                symbol: "hammer.fill"
            ),
            ProgressMetricComparison(
                title: "平均状态评分",
                current: current.moodAverage.map { "\(Int($0.rounded())) 分" } ?? "未知",
                previous: previous.moodAverage.map { "\(Int($0.rounded())) 分" } ?? "未知",
                change: scoreChange(current.moodAverage, previous.moodAverage),
                coverage: current.moodDays > 0 ? "\(current.moodDays) 天有评分" : "没有评分，不按零计算",
                symbol: "waveform.path.ecg"
            ),
            ProgressMetricComparison(
                title: "娱乐识别时长",
                current: current.entertainmentDuration.map(ActivityFormatter.time) ?? "未知",
                previous: previous.entertainmentDuration.map(ActivityFormatter.time) ?? "未知",
                change: durationChange(current.entertainmentDuration, previous.entertainmentDuration),
                coverage: current.recordedDays > 0 ? "按应用类别统计 · 覆盖 \(current.recordedDays) 天" : "没有可比较的实时足迹",
                symbol: "play.rectangle"
            ),
            ProgressMetricComparison(
                title: "活跃记录天数",
                current: "\(current.recordedDays) 天",
                previous: "\(previous.recordedDays) 天",
                change: countChange(current.recordedDays, previous.recordedDays),
                coverage: "macOS 实时片段 · 每期 \(dayCount) 天",
                symbol: "clock"
            ),
            ProgressMetricComparison(
                title: "平均步数",
                current: current.averageSteps.map { "\(Int($0.rounded())) 步/天" } ?? "未知",
                previous: previous.averageSteps.map { "\(Int($0.rounded())) 步/天" } ?? "未知",
                change: scoreChange(current.averageSteps, previous.averageSteps, unit: "步/天"),
                coverage: current.stepDays > 0 ? "\(current.stepDays) 天有健康数据" : "没有健康数据，不按零计算",
                symbol: "figure.walk"
            ),
            ProgressMetricComparison(
                title: "写下日记",
                current: "\(current.writingDays) 天",
                previous: "\(previous.writingDays) 天",
                change: countChange(current.writingDays, previous.writingDays),
                coverage: "本机已载入的日记记录",
                symbol: "book.closed"
            ),
            ProgressMetricComparison(
                title: "每日目标完成",
                current: goalSummary(current),
                previous: goalSummary(previous),
                change: goalCompletionChange(current, previous),
                coverage: current.goalDays > 0 ? "你设定了 \(current.goalDays) 天的目标" : "没有目标记录，不按未完成计算",
                symbol: "target"
            )
        ]

        return RiverPanel(title: "所有指标对照", systemImage: "tablecells", accent: AppTheme.accent) {
            VStack(spacing: 0) {
                HStack(spacing: density.spacing(AppSpacing.md)) {
                    Text("指标").frame(width: ProgressColumnMetrics.labelColumn, alignment: .leading)
                    Text("本周期").frame(width: ProgressColumnMetrics.valueColumn, alignment: .leading)
                    Text("上一周期").frame(width: ProgressColumnMetrics.valueColumn, alignment: .leading)
                    Text("变化").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(AppTypography.kicker())
                .foregroundStyle(Color.tertiaryInk)
                .padding(.bottom, density.spacing(AppSpacing.sm))
                RiverRowDivider(inset: -AppSpacing.panelPadding)
                    .padding(.bottom, density.spacing(AppSpacing.xxs))
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    ProgressComparisonRow(row: row)
                        .overlay(alignment: .bottom) {
                            if index < rows.count - 1 { RiverRowDivider(inset: 0) }
                        }
                }
            }
        }
    }
}

private struct ProgressTrendPoint: Identifiable {
    let dayIndex: Int
    let hours: Double
    let isCurrent: Bool
    let segment: Int

    var id: String { "\(isCurrent)-\(segment)-\(dayIndex)" }
    var series: String { "\(isCurrent ? "current" : "previous")-\(segment)" }
}

private struct ProgressFocusTrendChart: View {
    @Environment(\.riverDensity) private var density
    let current: [ProgressTrendPoint]
    let previous: [ProgressTrendPoint]
    let dayCount: Int
    let currentCoverage: Int
    let previousCoverage: Int

    private var points: [ProgressTrendPoint] { current + previous }
    private var axisDays: [Int] { Array(Set([0, dayCount / 2, max(0, dayCount - 1)])).sorted() }

    var body: some View {
        RiverPanel(title: "每日实时专注", systemImage: "chart.xyaxis.line", accent: AppTheme.accent) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.md)) {
                if points.isEmpty {
                    EmptyStateView(
                        title: "这两个周期都没有足够的实时足迹绘制趋势。",
                        message: "未记录的日期留空，不按零计算。",
                        symbol: "chart.line.uptrend.xyaxis",
                        showsChrome: false
                    )
                } else {
                    Chart(points) { point in
                        LineMark(
                            x: .value("周期日", point.dayIndex),
                            y: .value("专注小时", point.hours),
                            series: .value("连续记录段", point.series)
                        )
                        .foregroundStyle(point.isCurrent ? AppTheme.accent : Color.secondaryInk)
                        .lineStyle(StrokeStyle(lineWidth: point.isCurrent ? 2.5 : 1.5))

                        PointMark(
                            x: .value("周期日", point.dayIndex),
                            y: .value("专注小时", point.hours)
                        )
                        .foregroundStyle(point.isCurrent ? AppTheme.accent : Color.secondaryInk)
                        .symbolSize(point.isCurrent ? 28 : 18)
                    }
                    .chartLegend(.hidden)
                    .chartXScale(domain: 0...max(1, dayCount - 1))
                    .chartXAxis {
                        AxisMarks(values: axisDays) { value in
                            AxisGridLine().foregroundStyle(Color.separator)
                            AxisValueLabel {
                                if let day = value.as(Int.self) {
                                    Text("第 \(day + 1) 天")
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine().foregroundStyle(Color.separator)
                            AxisValueLabel {
                                if let hours = value.as(Double.self) {
                                    Text(ActivityFormatter.time(hours * 3600))
                                }
                            }
                        }
                    }
                    .frame(height: 210)
                }

                HStack(spacing: density.spacing(AppSpacing.lg)) {
                    legend("本周期", color: .riverBlue, coverage: currentCoverage)
                    legend("上一周期", color: .secondaryInk, coverage: previousCoverage)
                }
                .font(AppTypography.metadata())
                .foregroundStyle(Color.secondaryInk)
                Text("横轴按周期中的第几天对齐；断线表示当天没有实时片段，不代表专注为零。")
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.secondaryInk)
            }
        }
    }

    private func legend(_ title: String, color: Color, coverage: Int) -> some View {
        HStack(spacing: density.spacing(6)) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(title) · 有实时足迹 \(coverage)/\(dayCount) 天")
        }
    }
}

private struct ProgressMetricComparison: Identifiable {
    let title: String
    let current: String
    let previous: String
    let change: String
    let coverage: String
    let symbol: String

    var id: String { title }
}

private struct ProgressComparisonRow: View {
    @Environment(\.riverDensity) private var density
    let row: ProgressMetricComparison

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(5)) {
            HStack(alignment: .firstTextBaseline, spacing: density.spacing(AppSpacing.md)) {
                Label(row.title, systemImage: row.symbol)
                    .font(AppTypography.secondary())
                    .foregroundStyle(Color.ink)
                    .frame(width: ProgressColumnMetrics.labelColumn, alignment: .leading)
                Text(row.current)
                    .font(AppTypography.primary().weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.ink)
                    .frame(width: ProgressColumnMetrics.valueColumn, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(row.previous)
                    .font(AppTypography.secondary().monospacedDigit())
                    .foregroundStyle(Color.secondaryInk)
                    .frame(width: ProgressColumnMetrics.valueColumn, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(row.change)
                    .font(AppTypography.secondary())
                    .foregroundStyle(AppTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
            Text(row.coverage)
                .font(AppTypography.metadata())
                .foregroundStyle(Color.secondaryInk)
                .padding(.leading, ProgressColumnMetrics.leadingOffset)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, density.spacing(10))
        .accessibilityElement(children: .combine)
    }
}

/// Shared column grid of the comparison table. The header row and the data rows
/// must agree on these widths, and the coverage line must indent to the first
/// value column, so the numbers live here once instead of being repeated.
private enum ProgressColumnMetrics {
    static let labelColumn: CGFloat = 148
    static let valueColumn: CGFloat = 108
    static let leadingOffset: CGFloat = 160
}
