import SwiftUI

/// 常驻证据控制台（右栏静息态）。
///
/// DESIGN.md 规划的"右侧证据控制台"：宽窗（≥1320pt）且未选中任何节点时，
/// 右列不停留在空白，而是回答三个始终成立的问题——
/// 仪器在工作吗（正在记录）、有什么需要我纠正（待确认）、数据在我手里吗（信任）。
/// 选中时间线节点后，同一列被证据详情（InspectorPanel）接管。
///
/// 窄窗下整列收起，不挤压内容。
struct EvidenceConsoleView: View {
    @Environment(\.riverDensity) private var density
    @EnvironmentObject private var feedbackCenter: FeedbackCenter
    /// 行内快速标注：展开输入框的那条队列行（nil = 无）。
    @State private var annotatingItemID: String?
    @State private var annotationDraft = ""
    @FocusState private var annotationFieldFocused: Bool
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ingestion: DataIngestionStore
    /// 与全进程共享的 V2 连接；信任卡读取证据规模。
    let v2Store: V2Store
    let selectedDate: Date
    var onSelectTimelineItem: (ActivityTimelineItem, String) -> Void
    var onStartTracking: () -> Void

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
                nowCard
                reviewQueueCard
                trustCard
            }
            .padding(.leading, density.spacing(AppSpacing.md))
            .padding(.trailing, density.spacing(AppSpacing.page))
            .padding(.top, AppSpacing.headerTop)
            .padding(.bottom, density.spacing(AppSpacing.lg))
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.workspace)
        .overlay(alignment: .leading) { RiverRule().frame(width: 1) }
    }

    // MARK: - 正在记录

    private var nowCard: some View {
        RiverPanel(title: "正在记录", systemImage: "dot.radiowaves.left.and.right", accent: AppTheme.accent) {
            if activity.isTracking {
                VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
                    if let active = activity.activeSession {
                        HStack(spacing: density.spacing(AppSpacing.sm)) {
                            Circle()
                                .fill(AppTheme.recording)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(active.appName)
                                .font(AppTypography.rowTitle())
                                .foregroundStyle(Color.ink)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(ActivityFormatter.time(Date().timeIntervalSince(active.start)))
                                .font(AppTypography.numeric())
                                .foregroundStyle(Color.secondaryInk)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("正在记录 \(active.appName)，已持续 \(ActivityFormatter.time(Date().timeIntervalSince(active.start)))")
                    } else {
                        Text("当前没有前台片段；应用切换后会自动继续。")
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    todayTotalRow
                    if let saved = activity.lastSavedAt {
                        Text("上次保存 \(saved.formatted(date: .omitted, time: .shortened))")
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.tertiaryInk)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
                    Text("实时记录未开启。")
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("开始记录") { onStartTracking() }
                        .buttonStyle(.plain)
                        .smallAction()
                }
            }
        }
    }

    private var todayTotalRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("今日已记录")
                .font(AppTypography.label())
                .foregroundStyle(Color.secondaryInk)
            Spacer(minLength: 0)
            Text(ActivityFormatter.time(todayTotal))
                .font(AppTypography.numeric())
                .foregroundStyle(Color.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private var todayTotal: TimeInterval {
        activity
            .liveSessions(for: Date())
            .reduce(0) { $0 + max($1.duration, $1.end.timeIntervalSince($1.start)) }
    }

    // MARK: - 待确认

    private var reviewQueueCard: some View {
        let timeline = buildTimeline()
        let items = Array(timeline.items
            .filter(\.needsReview)
            .sorted { $0.reviewSpan > $1.reviewSpan }
            .prefix(4))

        return RiverPanel(
            title: "需要你确认",
            systemImage: "questionmark.circle",
            detail: items.isEmpty ? "没有待确认项" : "\(items.count) 条",
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
                        consoleReviewRow(item)
                        if index < items.count - 1 { RiverRowDivider(inset: density.spacing(AppSpacing.sm)) }
                    }
                }
                Text("写一句补全说明，或标记不用管；点行打开证据详情。")
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
    private func consoleReviewRow(_ item: ActivityTimelineItem) -> some View {
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
                    Text("\(item.needsReviewReason ?? "待确认") · \(item.start.formatted(date: .omitted, time: .shortened))–\(item.end.formatted(date: .omitted, time: .shortened))")
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
                    TextField("写一句说明，比如：备课时间", text: $annotationDraft)
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
        } catch {
            feedbackCenter.show("保存失败：\(UserFacingError.message(for: error))", kind: .error)
        }
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

    // MARK: - 信任

    private var trustCard: some View {
        RiverPanel(title: "信任", systemImage: "lock.shield", accent: AppTheme.ok) {
            VStack(spacing: 0) {
                HStack(spacing: density.spacing(AppSpacing.sm)) {
                    Text("本机加密")
                        .font(AppTypography.label())
                        .foregroundStyle(Color.secondaryInk)
                    Spacer(minLength: 0)
                    StatusBadge(store.isEncrypted ? "已开启" : "未开启", tone: store.isEncrypted ? .positive : .attention)
                }
                .padding(.vertical, density.spacing(6))
                RiverRowDivider(inset: 0)
                trustRow(title: "上次采集", value: lastCaptureText)
                trustRow(title: "V2 证据", value: "\(v2Store.countRows(in: .rawEvents)) 条原始事件")
                trustRow(title: "实时片段", value: "\(activity.sessions.count) 段 · 近 365 天", showsDivider: false)
            }
        }
    }

    private var lastCaptureText: String {
        if let last = ingestion.lastIngestedAt {
            let prefix = Calendar.current.isDateInToday(last) ? "今天 " : ""
            return "\(prefix)\(last.formatted(date: .omitted, time: .shortened))"
        }
        return ingestion.enabled ? "等待下一次采集" : "未启用"
    }

    private func trustRow(title: String, value: String, showsDivider: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(AppTypography.label())
                .foregroundStyle(Color.secondaryInk)
            Spacer(minLength: 0)
            Text(value)
                .font(AppTypography.metadata())
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, density.spacing(6))
        .overlay(alignment: .bottom) {
            if showsDivider { RiverRowDivider(inset: 0) }
        }
        .accessibilityElement(children: .combine)
    }
}
