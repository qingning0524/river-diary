import SwiftUI

/// 常驻待确认队列。实时记录状态位于今日页，信任与存储信息位于设置；
/// 右栏只呈现需要用户补充或确认的证据。选中时间线节点后，InspectorPanel 接管此列。
struct EvidenceConsoleView: View {
    @Environment(\.riverDensity) private var density
    @EnvironmentObject private var feedbackCenter: FeedbackCenter
    /// 行内快速标注：展开输入框的那条队列行（nil = 无）。
    @State private var annotatingItemID: String?
    @State private var annotationDraft = ""
    @FocusState private var annotationFieldFocused: Bool
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    let selectedDate: Date
    var onSelectTimelineItem: (ActivityTimelineItem, String) -> Void

    private var entry: DiaryEntry { store.entry(for: selectedDate) }

    /// 每帧构建一次时间线；控制台只在 store 发布变更时重渲染。
    private func buildTimeline() -> ActivityTimeline {
        ActivityTimelineEngine.build(
            for: selectedDate,
            sessions: activity.liveSessions(for: selectedDate),
            captures: store.captures(for: entry),
            annotations: store.timelineAnnotations
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.panelGap)) {
                reviewQueueCard
            }
            .padding(.leading, density.spacing(AppSpacing.md))
            .padding(.trailing, density.spacing(AppSpacing.page))
            .padding(.top, AppSpacing.headerTop)
            .padding(.bottom, density.spacing(AppSpacing.lg))
        }
        .riverScrollIndicators()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.workspace)
        .overlay(alignment: .leading) { RiverRule().frame(width: 1) }
    }

    // MARK: - 待确认

    private var reviewQueueCard: some View {
        let timeline = buildTimeline()
        let dayKey = DiaryEntry.dateFormatter.string(from: selectedDate)
        let digest = ai.storedTimelineDigest(for: dayKey)
        let currentFingerprint = ai.currentTimelineSourceFingerprint(
            day: selectedDate,
            entries: [entry],
            sessions: timeline.sessions,
            captures: store.captures(for: entry),
            browserVisits: AppDatabase.shared.chromeVisits(for: dayKey),
            annotations: store.timelineAnnotations
        )
        let clarifications = Dictionary(
            (digest?.sourceFingerprint == currentFingerprint ? digest?.clarifications ?? [] : [])
                .filter { ai.isTimelineClarificationPending(candidateID: $0.candidateID) }
                .map { ($0.candidateID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let items = Array(timeline.foldedItems
            .filter { $0.needsReview || clarifications[$0.id] != nil }
            .sorted { $0.reviewSpan > $1.reviewSpan }
            .prefix(4))

        return RiverPanel(
            title: "需要你确认",
            systemImage: "questionmark.circle",
            detail: items.isEmpty ? "没有待确认项" : "\(items.count) 段活动需要补充理解",
            accent: AppTheme.warning
        ) {
            if items.isEmpty {
                HStack(spacing: density.spacing(AppSpacing.sm)) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(AppTheme.ok)
                        .accessibilityHidden(true)
                    Text("\(Calendar.current.isDateInToday(selectedDate) ? "今天" : "这一天")没有需要确认的时间片。")
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        consoleReviewRow(item, clarification: clarifications[item.id])
                        if index < items.count - 1 { RiverRowDivider(inset: density.spacing(AppSpacing.sm)) }
                    }
                }
                Text("AI 的观察只针对这段记录；你可以用自己的话补充，或点行查看来源。")
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.tertiaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, density.spacing(AppSpacing.sm))
            }
        }
    }

    /// 一条待确认证据：是什么（标题）、为什么待确认（原因 + 时间范围）、
    /// 多长（时长），以及不打开详情就能完成的"确认"动作。
    /// 一条待确认证据：是什么、为什么待确认（原因 + 时间范围）、多长，
    /// 以及两个动作——"写一句"补全说明（主），"不用管"标记已知（次）。
    /// 点行本身仍打开完整证据详情。
    private func consoleReviewRow(_ item: ActivityTimelineItem, clarification: TimelineDigestClarification?) -> some View {
        let spanText = item.duration >= 60
            ? ActivityFormatter.time(item.duration)
            : "不到 1 分钟"
        let isAnnotating = annotatingItemID == item.id
        return VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xs)) {
            HStack(alignment: .top, spacing: density.spacing(AppSpacing.sm)) {
                VStack(alignment: .leading, spacing: density.spacing(2)) {
                    Text(item.title)
                        .font(AppTypography.rowTitle())
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Text("\(clarification?.opening ?? item.needsReviewReason ?? "待确认") · \(item.start.formatted(date: .omitted, time: .shortened))–\(item.end.formatted(date: .omitted, time: .shortened))")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.tertiaryInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
                Text(spanText)
                    .font(AppTypography.numeric())
                    .foregroundStyle(Color.secondaryInk)
            }
            .contentShape(Rectangle())
            .onTapGesture { openDetail(item) }

            if isAnnotating {
                HStack(spacing: density.spacing(AppSpacing.xs)) {
                    TextField("用自己的话补充或纠正这段活动", text: $annotationDraft)
                        .textFieldStyle(.plain)
                        .font(AppTypography.secondary())
                        .focused($annotationFieldFocused)
                        .onSubmit { saveQuickAnnotation(item) }
                        .padding(density.spacing(AppSpacing.xs))
                        .background(Color.editor, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                                .strokeBorder(Color.border, lineWidth: 1)
                        )
                    Button("保存") { saveQuickAnnotation(item) }
                        .primaryCTA()
                    Button("取消") { closeAnnotating() }
                        .linkAction()
                }
            } else {
                HStack(spacing: density.spacing(AppSpacing.md)) {
                    Button {
                        annotatingItemID = item.id
                        annotationDraft = ""
                        annotationFieldFocused = true
                    } label: {
                        Label("写一句", systemImage: "square.and.pencil")
                            .font(AppTypography.metadata())
                    }
                    .linkAction()
                    .accessibilityLabel("为 \(item.title) 补充一句说明")
                    Button("不用管") { dismiss(item) }
                        .linkAction()
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.tertiaryInk)
                        .accessibilityLabel("不用管：\(item.title) 标记为已确认")
                }
            }
        }
        .padding(.vertical, density.spacing(6))
        .accessibilityElement(children: .contain)
        .accessibilityHint("点行查看详情；写一句补全说明，或不用管")
    }

    private func openDetail(_ item: ActivityTimelineItem) {
        closeAnnotating()
        onSelectTimelineItem(item, "console-review:\(item.id)")
    }

    private func closeAnnotating() {
        annotatingItemID = nil
        annotationDraft = ""
    }

    /// "写一句"：把这句话存成该节点的整理标题并视为已确认。
    /// 时间线上的节点会随之改名——补充立刻可见。
    private func saveQuickAnnotation(_ item: ActivityTimelineItem) {
        guard let key = item.annotationKey else { return }
        let trimmed = annotationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var annotation = store.timelineAnnotations[key] ?? TimelineAnnotation()
        annotation.title = trimmed
        annotation.isReviewed = true
        annotation.reviewedAt = Date()
        do {
            try store.saveTimelineAnnotation(annotation, for: key)
            feedbackCenter.show("已补充：\(trimmed)", kind: .success)
            closeAnnotating()
            Task { await reanalyzeSelectedDayAfterCorrection() }
        } catch {
            feedbackCenter.show("保存失败：\(UserFacingError.message(for: error))", kind: .error)
        }
    }

    @MainActor
    private func reanalyzeSelectedDayAfterCorrection() async {
        guard ai.analysisReady else { return }
        let dayKey = DiaryEntry.dateFormatter.string(from: selectedDate)
        let dayEntry = store.entry(for: selectedDate)
        let dayCaptures = store.captures(for: dayEntry)
        let sessions = activity.liveSessions(for: selectedDate)
        let browserVisits = AppDatabase.shared.chromeVisits(for: dayKey)
        let dayEntries = store.entries.filter { $0.date == dayKey }
        let annotations = store.timelineAnnotations
        _ = await ai.organizeTimeline(
            day: selectedDate,
            entries: dayEntries,
            sessions: sessions,
            captures: dayCaptures,
            browserVisits: browserVisits,
            annotations: annotations,
            sourceSummary: "用户补充时间线 · \(dayKey)"
        )
        _ = await ai.runAnalysisDaily(
            entries: dayEntries,
            sessions: sessions,
            captures: dayCaptures,
            browserVisits: browserVisits,
            annotations: annotations,
            archiveStartDate: dayKey,
            archiveEndDate: dayKey,
            sourceSummary: "用户补充后重新理解当天 · \(dayKey)"
        )
    }

    /// "不用管"：我知道这段时间是什么，不需要说明。
    private func dismiss(_ item: ActivityTimelineItem) {
        guard let key = item.annotationKey else { return }
        var annotation = store.timelineAnnotations[key] ?? TimelineAnnotation()
        annotation.isReviewed = true
        annotation.reviewedAt = Date()
        do {
            try store.saveTimelineAnnotation(annotation, for: key)
            feedbackCenter.show("已标记不用管", kind: .success)
        } catch {
            feedbackCenter.show("保存失败：\(UserFacingError.message(for: error))", kind: .error)
        }
    }

}
