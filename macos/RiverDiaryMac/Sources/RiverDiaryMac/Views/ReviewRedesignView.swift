import AppKit
import SwiftUI

/// Standalone review route. The actual review content is reusable inside Memory.
struct ReviewRedesignView: View {
    @Environment(\.riverDensity) private var density
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var library: MemoryLibraryStore
    let selectedDate: Date
    /// 把 AI 结论里的证据引用交给 Shell 打开 Inspector。
    var onRevealEvidence: (String, [AskEvidence]) -> Void = { _, _ in }

    var body: some View {
        RiverPage {
            ReviewContentView(
                store: store,
                activity: activity,
                ai: ai,
                library: library,
                selectedDate: selectedDate,
                onRevealEvidence: onRevealEvidence
            )
        }
    }
}

/// Non-scrolling review content. Memory embeds this view so its parent remains
/// the only vertical scroll owner and the review does not become a mini-app.
struct ReviewContentView: View {
    @Environment(\.riverDensity) private var density
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var library: MemoryLibraryStore
    let selectedDate: Date

    @State private var dayRange = 7
    @State private var editingLetter: MonthlyLetter?
    @State private var letterDrafts: [String: MonthlyLetter] = [:]
    @State private var letterMessage: String?
    var showsHeader = true
    var onRevealEvidence: (String, [AskEvidence]) -> Void = { _, _ in }
    @EnvironmentObject private var feedbackCenter: FeedbackCenter

    private var endDate: Date { ProgressAnchor.completedEndDate(selectedDate: selectedDate) }
    private var startDate: Date {
        Calendar.current.date(byAdding: .day, value: -(dayRange - 1), to: endDate) ?? endDate
    }

    /// 周期内每天各构建一次时间线引擎，7/30 天就是 7/30 次构建——
    /// body 每帧只允许调用一次，各分段接收现成结果。
    private func makeReview() -> LocalReview {
        LocalReview.make(
            start: startDate,
            end: endDate,
            entries: store.entries,
            sessions: activity.sessions(from: startDate, to: endDate.addingTimeInterval(24 * 60 * 60)),
            captures: store.quickCaptures
        )
    }

    var body: some View {
        let review = makeReview()
        let switching = switchSummary()
        return VStack(alignment: .leading, spacing: density.spacing(16)) {
                if showsHeader {
                    PageHeader("回顾", context: "从几天的记录里，看见自己的节奏。", emphasis: true) {
                        rangePicker
                    }
                    .riverAppear(index: 0)
                } else {
                    HStack {
                        RiverSectionHeading(title: "周期回顾", detail: "从几天的记录里，看见自己的节奏")
                        Spacer()
                        rangePicker
                    }
                    .riverAppear(index: 0)
                }

                summary(review).riverAppear(index: 1)
                rhythm(review).riverAppear(index: 2)
                distribution(review, switching: switching).riverAppear(index: 3)
                monthlyLetter.riverAppear(index: 4)
                aiReview(review).riverAppear(index: 5)
                actionRow.riverAppear(index: 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { loadMonthlyLetter() }
        .onChange(of: endDate) { _, _ in loadMonthlyLetter() }
    }

    private var rangePicker: some View {
        RiverSegmentedPicker(
            title: "复盘范围",
            selection: $dayRange,
            options: [7, 30],
            label: { $0 == 7 ? "近 7 天" : "近 30 天" }
        )
    }

    private func summary(_ review: LocalReview) -> some View {
        RiverPanel(tint: AppTheme.accent) {
            HStack(alignment: .top, spacing: 0) {
                RiverStat(title: "写下日记", value: "\(review.writingDays) 天", detail: "\(dayRange) 天内", valueFont: AppTypography.metricSmall())
                RiverStatDivider()
                RiverStat(title: "快记", value: "\(review.captureCount) 条", detail: "手动留下", valueFont: AppTypography.metricSmall())
                RiverStatDivider()
                RiverStat(title: "实时足迹", value: ActivityFormatter.time(review.duration), detail: "已记录", valueFont: AppTypography.metricSmall())
                RiverStatDivider()
                RiverStat(
                    title: "平均心情",
                    value: review.averageMood.map { "\(Int($0.rounded()))" } ?? "—",
                    detail: review.moodSamples > 0 ? "\(review.moodSamples) 天评分" : "暂无评分",
                    valueFont: AppTypography.metricSmall()
                )
            }
        }
    }

    private func rhythm(_ review: LocalReview) -> some View {
        RiverPanel(title: "每日节律", systemImage: "waveform.path", accent: AppTheme.accent) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.md)) {
                // 柱高的分母在循环外算一次：放在每行的 GeometryReader 里
                // 会让每根柱子都重新扫描全部天。
                let maxDuration = max(review.days.map(\.duration).max() ?? 1, 1)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(review.days.enumerated()), id: \.element.id) { index, day in
                        VStack(spacing: density.spacing(5)) {
                            Text(day.mood.map { "\(Int($0.rounded()))" } ?? "—")
                                .font(AppTypography.numeric())
                                .foregroundStyle(day.mood == nil ? Color.tertiaryInk : Color.secondaryInk)
                                .frame(minHeight: 14)
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(day.mood == nil ? Color.tertiaryInk.opacity(0.25) : AppTheme.accent)
                                    .frame(height: max(8, proxy.size.height * min(1, day.duration / maxDuration)))
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                            .frame(height: 56)
                            Text(shouldShowDateLabel(index, dayCount: review.days.count) ? shortDate(day.id) : "")
                                .font(AppTypography.metadata().monospacedDigit())
                                .foregroundStyle(Color.tertiaryInk)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(day.id)，记录时长 \(ActivityFormatter.time(day.duration))，状态评分 \(day.mood.map { String(Int($0.rounded())) } ?? "未知")")
                    }
                }
                // 基线：柱子坐在同一条 1px 线上，不再像悬空的砖块。
                RiverRule()
                SettingsFootnote(text: "数字为已有状态评分；柱高表示实时记录量，灰色表示暂无评分。缺失不会按零计算。")
            }
        }
    }

    /// 一句话的切换叙述，只在"最忙的一天短切换显著"时说。
    ///
    /// 复盘是解读的家，时间线的行里永远不放这种句子。默认沉默是原则：
    /// 本机分布里每日短切换 p50 = 37、p90 = 121，所以门槛取 100——
    /// 大约只有最忙的一成天数会开口。措辞是模式描述，不是评价：
    /// 组合工作是常态，"分散"也只是说结构，不评判。
    ///
    /// 性能门槛：碎片段数 ≤ 段数（块由段合并而来），所以**段数不足 100 的天
    /// 不可能达到门槛**，直接跳过——30 天范围通常只构建一两天的时间线，
    /// 而不是 30 次。
    private func switchSummary() -> String? {
        let sessions = activity.sessions(from: startDate, to: endDate.addingTimeInterval(24 * 60 * 60))
        guard !sessions.isEmpty else { return nil }
        let rangeStart = Calendar.current.startOfDay(for: startDate)
        let rangeEnd = Calendar.current.startOfDay(for: endDate)

        var busiest: (date: Date, fragments: Int, composedRuns: Int, hasWandering: Bool, totalRuns: Int)?
        for (dayKey, daySessions) in Dictionary(grouping: sessions, by: \.dayKey)
        where daySessions.count >= 100 {
            guard let day = DiaryEntry.dateFormatter.date(from: dayKey) else { continue }
            let dayStart = Calendar.current.startOfDay(for: day)
            guard dayStart >= rangeStart, dayStart <= rangeEnd else { continue }
            let timeline = ActivityTimelineEngine.build(for: day, sessions: daySessions, captures: [])
            let fragments = timeline.fragmentNodeCount
            guard fragments >= 100 else { continue }
            let runs = timeline.foldedItems.filter(\.isFragmentRun)
            let shapes = runs.map(FragmentRunShape.classify)
            if fragments > (busiest?.fragments ?? 0) {
                busiest = (
                    dayStart,
                    fragments,
                    shapes.filter(\.isComposedWork).count,
                    shapes.contains(where: \.isWandering),
                    runs.count
                )
            }
        }

        guard let busiest else { return nil }
        let dateText = busiest.date.formatted(.dateTime.month().day())
        let head = "近 \(dayRange) 天里，\(dateText) 的短切换最多（\(busiest.fragments) 段）"
        // "多为"必须真的过半：恰好一半也说"多为"是不诚实的措辞。
        if busiest.composedRuns * 2 > busiest.totalRuns {
            return head + "，多为多工具之间的组合工作。"
        }
        if busiest.hasWandering {
            return head + "，部分时段分散在多个应用之间。"
        }
        return head + "。"
    }

    private func distribution(_ review: LocalReview, switching: String?) -> some View {
        RiverPanel(title: "时间分布", systemImage: "chart.bar", accent: AppTheme.accent) {
            VStack(alignment: .leading, spacing: density.spacing(9)) {
                if review.categories.isEmpty {
                    EmptyStateView(
                        title: "这段时间还没有足够的活动分类。",
                        message: "实时足迹和项目管道积累几天后，这里会给出分布。",
                        symbol: "chart.bar",
                        showsChrome: false
                    )
                } else {
                    let maxDuration = max(review.categories.first?.duration ?? 1, 1)
                    ForEach(Array(review.categories.prefix(6)), id: \.name) { category in
                        HStack(spacing: density.spacing(9)) {
                            Text(category.name)
                                .font(AppTypography.label())
                                .foregroundStyle(Color.ink)
                                .frame(width: 52, alignment: .leading)
                            GeometryReader { proxy in
                                // 每行都有轨道：小数值读作"轨道上的短填充"，
                                // 而不是一颗悬空的圆点。
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.editor)
                                    Capsule()
                                        .fill(AppTheme.categoryTint(category.name).opacity(0.85))
                                        .frame(width: max(8, proxy.size.width * category.duration / maxDuration))
                                }
                            }
                            .frame(height: 7)
                            Text(ActivityFormatter.time(category.duration))
                                .font(AppTypography.metadata().monospacedDigit())
                                .foregroundStyle(Color.secondaryInk)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(width: 88, alignment: .trailing)
                        }
                    }
                }
                if let switching {
                    SettingsFootnote(text: switching)
                }
            }
        }
    }

    private var monthlyLetter: some View {
        RiverPanel(title: "河流信", systemImage: "envelope.open", accent: AppTheme.accent) {
            VStack(alignment: .leading, spacing: density.spacing(10)) {
                if let letter = activeLetter {
                    Text(letter.title)
                        .font(AppTypography.sectionTitle())
                        .foregroundStyle(Color.ink)
                    TextEditor(text: Binding(
                        get: { editingLetter?.body ?? letter.body },
                        set: { editingLetter?.body = $0 }
                    ))
                    .font(AppTypography.secondary())
                    .frame(minHeight: 120, maxHeight: 180)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.hidden)
                    .padding(AppSpacing.sm)
                    .background(Color.editor, in: RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                            .strokeBorder(Color.border, lineWidth: 1)
                    )
                    Text("依据：\(letter.evidence)")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.tertiaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: density.spacing(AppSpacing.sm)) {
                        Button("保存河流信") { saveLetter() }
                            .primaryCTA()
                        Button(letter.isFavorite ? "取消收藏" : "收藏") {
                            editingLetter?.isFavorite.toggle()
                        }
                        .buttonStyle(.plain)
                        .smallAction()
                        Spacer()
                        Button("复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(letter.markdown, forType: .string)
                            feedbackCenter.show("已复制河流信", kind: .success)
                        }
                        .buttonStyle(.plain)
                        .smallAction()
                    }
                    if let letterMessage {
                        Text(letterMessage)
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.secondaryInk)
                    }
                } else {
                    EmptyStateView(
                        title: "本月还没有足够的记录生成河流信。",
                        message: "写日记、留快记或积累实时足迹后，这里会汇总成本月的河流信。",
                        symbol: "envelope.open",
                        showsChrome: false
                    )
                }
            }
        }
    }

    private var activeLetter: MonthlyLetter? {
        let key = MonthlyLetter.monthKey(for: endDate)
        if let editingLetter, editingLetter.month == key { return editingLetter }
        if let draft = letterDrafts[key] { return draft }
        return store.monthlyLetters[key] ?? MonthlyLetter.make(
            for: endDate,
            entries: store.entries,
            captures: store.quickCaptures,
            sessions: activity.allSessionsIncludingActive()
        )
    }

    private func loadMonthlyLetter() {
        if let editingLetter { letterDrafts[editingLetter.month] = editingLetter }
        let key = MonthlyLetter.monthKey(for: endDate)
        editingLetter = letterDrafts[key] ?? store.monthlyLetters[key] ?? MonthlyLetter.make(
            for: endDate,
            entries: store.entries,
            captures: store.quickCaptures,
            sessions: activity.allSessionsIncludingActive()
        )
        letterMessage = nil
    }

    private func saveLetter() {
        guard let letter = editingLetter ?? activeLetter else { return }
        do {
            try store.saveMonthlyLetter(letter)
            editingLetter = letter
            letterDrafts[letter.month] = nil
            library.refresh(entries: store.entries, captures: store.quickCaptures, letters: store.monthlyLetters)
            letterMessage = "已保存到加密本地状态。"
            feedbackCenter.show("已保存河流信", kind: .success)
        } catch {
            let message = UserFacingError.message(for: error)
            letterMessage = message
            feedbackCenter.show("保存失败：\(message)", kind: .error)
        }
    }

    private var actionRow: some View {
        HStack(spacing: density.spacing(AppSpacing.sm)) {
            Text("这份回顾只使用本机已有数据，不会自动请求 AI。")
                .font(AppTypography.metadata())
                .foregroundStyle(Color.secondaryInk)
            Spacer()
            Button("复制 Markdown") { copyMarkdown() }
                .buttonStyle(.plain)
                .smallAction()
            Button("导出 Markdown") { exportMarkdown() }
                .buttonStyle(.plain)
                .smallAction()
        }
    }

    private func aiReview(_ review: LocalReview) -> some View {
        RiverPanel(title: "AI 周期阅读", systemImage: "sparkles", accent: AppTheme.accent) {
            VStack(alignment: .leading, spacing: density.spacing(10)) {
                HStack {
                    Text(ai.hasVerifiedConnection ? "按需生成一份带范围依据的本周期观察" : "连接 AI 后，可以生成带依据的周期观察")
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.secondaryInk)
                    Spacer()
                    Button(ai.state(for: .analysisWeekly)?.isLoading == true ? "生成中…" : "生成阅读") {
                        Task {
                            await ai.runAnalysisWeekly(
                                entries: store.entries,
                                sessions: reviewSessions,
                                archiveStartDate: ActivitySession.dayKey(for: startDate),
                                archiveEndDate: ActivitySession.dayKey(for: endDate),
                                sourceSummary: "本机回顾 · \(dayRange) 天 · 日记 \(review.writingDays) 天 · 足迹 \(ActivityFormatter.time(review.duration))"
                            )
                            library.refresh(entries: store.entries, captures: store.quickCaptures, letters: store.monthlyLetters)
                        }
                    }
                    .primaryCTA()
                    .disabled(!ai.hasVerifiedConnection || ai.state(for: .analysisWeekly)?.isLoading == true)
                }
                payloadPreviewRow
                evidenceChipsRow(for: .analysisWeekly)
                if let state = ai.state(for: .analysisWeekly), let answer = state.answer {
                    Text(answer)
                        .font(AppTypography.primary())
                        .foregroundStyle(Color.ink)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                } else if let error = ai.state(for: .analysisWeekly)?.error {
                    Text(error)
                        .font(AppTypography.metadata())
                        .foregroundStyle(AppTheme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 请求前把"将要发送什么"摆在按钮下面：日记正文与窗口标题的敏感级别不同，
    /// 用户有权在按下生成之前看到数量，并单独决定是否附带窗口标题。
    private var payloadPreviewRow: some View {
        let preview = AIAssistantStore.preview(
            entries: store.entries,
            captures: store.quickCaptures.values.flatMap(\.self),
            sessions: reviewSessions,
            startDate: ActivitySession.dayKey(for: startDate),
            endDate: ActivitySession.dayKey(for: endDate),
            includesTitles: ai.includeTitles
        )
        return VStack(alignment: .leading, spacing: density.spacing(6)) {
            HStack(spacing: density.spacing(AppSpacing.sm)) {
                Image(systemName: "paperplane")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.tertiaryInk)
                    .accessibilityHidden(true)
                Text("将发送：\(preview.summary)")
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("附带窗口标题（更具体，也更敏感）", isOn: $ai.includeTitles)
                .toggleStyle(.switch)
                .tint(AppTheme.accent)
                .font(AppTypography.metadata())
        }
        .padding(.top, density.spacing(2))
    }

    /// AI 结论里写下的证据引用（`<!-- evidence: … -->` 或正文里的 `raw:`/`diary:` 形式）
    /// 渲染成可点的 chip：点一下就把这些记录送进 Inspector 核对。
    /// 这是"结论可追溯"从口号变成手感的那一步。
    @ViewBuilder
    private func evidenceChipsRow(for task: AITask) -> some View {
        let refs = EvidenceReference.extract(from: ai.state(for: task)?.answer ?? "")
        if !refs.isEmpty {
            let items = refs.prefix(8).map { ref -> AskEvidence in
                let parsed = EvidenceReference.parse(ref)
                let kind: AskEvidence.Kind = switch parsed?.kind {
                case .raw, .episode: .timeline
                case .capture: .capture
                case .health: .diary
                case .diary, .none: .diary
                }
                return AskEvidence(
                    id: ref,
                    kind: kind,
                    title: parsed.map { "\($0.kind.label) · \($0.value.prefix(8))" } ?? ref,
                    detail: ref,
                    date: parsed.flatMap { DiaryEntry.dateFormatter.date(from: $0.value) },
                    episodes: []
                )
            }
            VStack(alignment: .leading, spacing: density.spacing(6)) {
                Text("结论引用了 \(refs.count) 条本机记录")
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.tertiaryInk)
                ChipFlow(spacing: AppSpacing.sm) {
                    ForEach(items) { item in
                        FilterChip(title: item.title, isSelected: false) {
                            onRevealEvidence("AI 结论依据", Array(items))
                        }
                    }
                }
            }
        }
    }

    private var reviewSessions: [ActivitySession] {
        activity.sessions(from: startDate, to: endDate.addingTimeInterval(24 * 60 * 60))
    }

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(makeReview().markdown, forType: .string)
        feedbackCenter.show("已复制回顾 Markdown", kind: .success)
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "河流回顾-\(ActivitySession.dayKey(for: endDate)).md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try makeReview().markdown.write(to: url, atomically: true, encoding: .utf8)
            feedbackCenter.show("已导出回顾 Markdown", kind: .success)
        } catch {
            feedbackCenter.show("导出失败：\(UserFacingError.message(for: error))", kind: .error)
        }
    }

    private func shortDate(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3 else { return key }
        return "\(parts[1]).\(parts[2])"
    }

    private func shouldShowDateLabel(_ index: Int, dayCount: Int) -> Bool {
        let interval = dayRange <= 7 ? 1 : 7
        return index == 0 || index == dayCount - 1 || index.isMultiple(of: interval)
    }

}
