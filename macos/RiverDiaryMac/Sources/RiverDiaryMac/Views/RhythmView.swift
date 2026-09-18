import SwiftUI

struct RhythmView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @Binding var anchorDate: Date
    var showsHeader: Bool = true

    @State private var selectedDays = 30
    @State private var selectedMetric: RhythmMetric = .overall

    private var endDate: Date { Calendar.current.startOfDay(for: anchorDate) }
    private var startDate: Date {
        Calendar.current.date(byAdding: .day, value: -(selectedDays - 1), to: endDate) ?? endDate
    }

    private var periodEntries: [DiaryEntry] {
        let startKey = DiaryEntry.dateFormatter.string(from: startDate)
        let endKey = DiaryEntry.dateFormatter.string(from: endDate)
        return store.entries
            .filter { $0.date >= startKey && $0.date <= endKey }
            .sorted { $0.date < $1.date }
    }

    private var periodSessions: [ActivitySession] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: endDate) ?? endDate
        return activity.sessions(from: startDate, to: end)
    }

    private var periodCaptures: [QuickCapture] {
        let startKey = DiaryEntry.dateFormatter.string(from: startDate)
        let endKey = DiaryEntry.dateFormatter.string(from: endDate)
        return store.quickCaptures
            .filter { $0.key >= startKey && $0.key <= endKey }
            .flatMap { $0.value }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var monthInterval: DateInterval {
        Calendar.current.dateInterval(of: .month, for: endDate)
            ?? DateInterval(start: endDate, duration: 24 * 60 * 60)
    }

    private var monthDays: [Date] {
        let calendar = Calendar.current
        guard let dayRange = calendar.range(of: .day, in: .month, for: monthInterval.start) else { return [] }
        return dayRange.compactMap { day in
            calendar.date(bySetting: .day, value: day, of: monthInterval.start)
        }
    }

    private var monthLeadingEmptyCount: Int {
        max(0, Calendar.current.component(.weekday, from: monthInterval.start) - 1)
    }

    private var monthEntriesByDate: [String: DiaryEntry] {
        store.entries.reduce(into: [String: DiaryEntry]()) { result, entry in
            result[entry.date] = entry
        }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: monthInterval.start)
    }

    private var monthEntryCount: Int {
        let keys = Set(monthDays.map { DiaryEntry.dateFormatter.string(from: $0) })
        return keys.intersection(monthEntriesByDate.keys).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showsHeader {
                    header
                }
                controlPanel
                monthGridCard
                metricCard
                connectionCard
                lifeSegmentCard
                MonthlyLetterCard(store: store, activity: activity, date: $anchorDate)
            }
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: AppLayout.contentMaxWidth, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("节律")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.ink)
                StatusBadge(periodEntries.isEmpty ? "慢慢来" : "近 \(selectedDays) 天", tone: .neutral)
            }
            Text("情绪、专注、健康和足迹被放在一起看。它不评价你，只帮你看见自己正在怎样流动。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controlPanel: some View {
        SoftCard(padding: 14) {
            HStack(spacing: 8) {
                ForEach([7, 14, 30, 90], id: \.self) { days in
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { selectedDays = days }
                    } label: {
                        Text("\(days) 天")
                            .font(.ui(12, weight: selectedDays == days ? .semibold : .medium))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(
                                selectedDays == days ? AnyShapeStyle(LinearGradient.river()) : AnyShapeStyle(Color.chip),
                                in: Capsule()
                            )
                            .foregroundStyle(selectedDays == days ? .white : Color.secondaryInk)
                            .shadow(
                                color: selectedDays == days ? Color.riverAmethyst.opacity(0.3) : .clear,
                                radius: 6, x: 0, y: 3
                            )
                    }
                    .buttonStyle(.softPress)
                }

                Spacer()
                Text("\(periodEntries.count) 天记录 · \(periodSessions.count) 段足迹")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var metricCard: some View {
        return SoftCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("节律曲线", systemImage: "chart.dots.scatter")
                        .font(.headline)
                    Spacer()
                    Picker("指标", selection: $selectedMetric) {
                        ForEach(RhythmMetric.allCases) { metric in
                            Text(metric.title).tag(metric)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .tint(Color.riverAmethyst)
                    .controlSize(.large)
                    .frame(width: 400)
                }

                if periodEntries.compactMap({ selectedMetric.value($0) }).isEmpty {
                    Text("这段时间还没有评分。有记录的日子，自然会流进来。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    RhythmChart(entries: periodEntries, metric: selectedMetric)
                        .frame(height: 190)

                    HStack(spacing: 12) {
                        rhythmSummary("平均", averageText)
                        rhythmSummary("最高", "\(Int((periodEntries.compactMap { selectedMetric.value($0) }.max() ?? 0)))")
                        rhythmSummary("最低", "\(Int((periodEntries.compactMap { selectedMetric.value($0) }.min() ?? 0)))")
                        rhythmSummary("稳定度", "\(stability)/100")
                    }
                }
            }
        }
    }

    private var monthGridCard: some View {
        let entriesByDate = monthEntriesByDate

        return SoftCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Label("月度节律", systemImage: "calendar")
                        .font(.headline)
                    Spacer()
                    Text("\(monthTitle) · \(selectedMetric.title)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text("每一格只是当天的形状；留白也属于这段时间。点击某天可回到那一天。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 7),
                    spacing: 7
                ) {
                    ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { weekday in
                        Text(weekday)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }

                    ForEach(0..<monthLeadingEmptyCount, id: \.self) { _ in
                        Color.clear.frame(height: 36)
                    }

                    ForEach(monthDays, id: \.self) { day in
                        let key = DiaryEntry.dateFormatter.string(from: day)
                        monthDayCell(day, entry: entriesByDate[key])
                    }
                }

                HStack(spacing: 12) {
                    monthLegend("暖", color: Color.riverPink)
                    monthLegend("平", color: Color.riverAmethyst)
                    monthLegend("冷", color: Color.riverBlue)
                    monthLegend("留白", color: Color.border)
                    Spacer()
                    Text("\(monthEntryCount) 天有记录")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func monthDayCell(_ day: Date, entry: DiaryEntry?) -> some View {
        let key = DiaryEntry.dateFormatter.string(from: day)
        let value = entry.flatMap { selectedMetric.value($0) }
        let isSelected = Calendar.current.isDate(day, inSameDayAs: anchorDate)

        return Button {
            anchorDate = day
        } label: {
            VStack(spacing: 4) {
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.ink : .secondary)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(monthColor(for: value))
                    .frame(height: 13)
                    .overlay {
                        if let value {
                            Text("\(Int(value.rounded()))")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.chip : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.riverPink.opacity(0.75), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .help(entry == nil ? "\(key)：留白" : "\(key)：\(Int(value ?? 0))")
    }

    private func monthColor(for value: Double?) -> Color {
        guard let value else { return Color.border.opacity(0.45) }
        if value >= 80 { return Color.riverPink }
        if value >= 60 { return Color.riverAmethyst }
        if value >= 40 { return Color.riverBlue.opacity(0.82) }
        return Color.riverBlue.opacity(0.52)
    }

    private func monthLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private var averageText: String {
        let values = periodEntries.compactMap { selectedMetric.value($0) }
        guard !values.isEmpty else { return "—" }
        return String(Int(values.reduce(0, +) / Double(values.count)))
    }

    private var stability: Int {
        let values = periodEntries.compactMap { selectedMetric.value($0) }
        guard values.count > 1 else { return values.isEmpty ? 0 : 100 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count)
        let sd = sqrt(variance)
        return max(0, min(100, Int(100 - sd * 2.2)))
    }

    private var connectionCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("看得见的连接", systemImage: "link")
                    .font(.headline)

                if periodEntries.count < 3 {
                    Text("再攒几天记录，这里就会出现更可靠的线索。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let rows = [
                        connection("专注更高时，产出常常也在变好", metrics: [.focus, .output]),
                        connection("情绪更暖时，精力常常也更轻盈", metrics: [.mood, .energy]),
                        connection("身体更活跃时，整体节律也许更稳", metrics: [.energy, .overall])
                    ]

                    ForEach(rows, id: \.title) { row in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: row.strengthIcon)
                            .foregroundStyle(row.color)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.ink)
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(11)
                    .background(Color.chip, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                }
            }
        }
    }

    private var recentDailySegments: [TimelineSegment] {
        let grouped = Dictionary(grouping: periodSessions, by: \ .dayKey)
        return grouped.compactMap { key, sessions -> [TimelineSegment]? in
            guard let date = DiaryEntry.dateFormatter.date(from: key) else { return nil }
            return TimelineSegmentEngine.segments(for: date, sessions: sessions, quickCaptures: periodCaptures)
        }
        .flatMap { $0 }
        .filter { !$0.isEmpty }
        .sorted { $0.date > $1.date || ($0.date == $1.date && $0.start > $1.start) }
    }

    private var lifeSegmentCard: some View {
        let segments = Array(recentDailySegments.prefix(6))

        return SoftCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("生活段落", systemImage: "square.split.2x2")
                        .font(.headline)
                    Spacer()
                    Text("最近片段 · 与足迹页同一引擎")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if segments.isEmpty {
                    Text("还没有足够的应用片段。等你使用 Mac，时间会慢慢拼出形状。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 9) {
                        ForEach(segments) { segment in
                            TimelineSegmentRow(segment: segment)
                        }
                    }

                    if recentDailySegments.count > segments.count {
                        Text("只显示最近 \(segments.count) 个段落，完整节奏请去足迹页查看。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func rhythmSummary(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(value)
                .font(.editorial(18))
                .foregroundStyle(Color.ink)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.chip, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.border.opacity(0.7), lineWidth: 1)
        )
    }

    private func connection(_ title: String, metrics: [RhythmMetric]) -> ConnectionRow {
        let values = periodEntries.compactMap { entry -> (Double, Double)? in
            guard let first = metrics[0].value(entry), let second = metrics[1].value(entry) else { return nil }
            return (first, second)
        }
        let score = Pearson.compute(values)
        let strength = score >= 0.55 ? "连接很明显" : score >= 0.3 ? "有一点线索" : score >= 0 ? "关联还比较弱" : "方向暂时相反"
        let color = score >= 0.55 ? Color(hex: "#2C8158") : score >= 0.3 ? Color(hex: "#B26B00") : Color.secondaryInk
        let icon = score >= 0.55 ? "sparkles" : score >= 0.3 ? "questionmark.circle" : "minus.circle"
        return ConnectionRow(
            title: title,
            detail: "\(strength) · 相关系数 \(String(format: "%.2f", score))，来自 \(values.count) 天记录。",
            strengthIcon: icon,
            color: color
        )
    }
}

private struct ConnectionRow {
    var title: String
    var detail: String
    var strengthIcon: String
    var color: Color
}

enum RhythmMetric: String, CaseIterable, Identifiable {
    case overall, mood, energy, focus, output

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overall: "整体"
        case .mood: "情绪"
        case .energy: "精力"
        case .focus: "专注"
        case .output: "产出"
        }
    }

    func value(_ entry: DiaryEntry) -> Double? {
        let metric = entry.metrics
        switch self {
        case .overall: return metric?.overall ?? entry.score
        case .mood: return metric?.mood
        case .energy: return metric?.energy
        case .focus: return metric?.focus
        case .output: return metric?.output
        }
    }
}

struct RhythmChart: View {
    let entries: [DiaryEntry]
    let metric: RhythmMetric

    var body: some View {
        GeometryReader { proxy in
            let values = entries.compactMap { metric.value($0) }.filter(\.isFinite)
            let width = proxy.size.width
            let height = proxy.size.height
            let step = values.count > 1 ? width / CGFloat(values.count - 1) : 0

            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height))
                    for (index, value) in values.enumerated() {
                        let x = CGFloat(index) * step
                        let y = height - max(0.04, min(1, value / 100)) * (height - 18)
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "#7886FF").opacity(0.22), Color(hex: "#7886FF").opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = CGFloat(index) * step
                        let y = height - max(0.04, min(1, value / 100)) * (height - 18)
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(
                    LinearGradient(colors: [Color(hex: "#7FB3FF"), Color(hex: "#7F83FF"), Color(hex: "#FF8FB3")], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )

                ForEach(values.indices, id: \.self) { index in
                    if index == values.count - 1 {
                        let x = CGFloat(index) * step
                        let value = values[index]
                        let y = height - max(0.04, min(1, value / 100)) * (height - 18)
                        Circle()
                            .fill(Color(hex: "#7F83FF"))
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .position(x: x, y: y)
                    }
                }
            }
        }
    }
}

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
