import SwiftUI

/// Trailing inspector used by Today / Memory / Ask to show evidence.
struct InspectorPanel: View {
    @Environment(\.riverDensity) private var density
    let content: InspectorContent?
    let onClose: () -> Void
    @ObservedObject var store: DiaryStore
    @ObservedObject var library: MemoryLibraryStore

    @State private var editingTitle = ""
    @State private var editingNote = ""
    @State private var editingPlaceName = ""
    @State private var editingActivityLabel = ""
    @State private var editingFavorite = false
    @State private var editingReviewed = false
    @State private var isEditing = false
    @State private var captureToDelete: QuickCapture?
    @State private var feedback: String?
    @EnvironmentObject private var feedbackCenter: FeedbackCenter

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Group {
                if let content {
                    switch content {
                    case .episode(let item):
                        episodeInspector(item)
                    case .evidence(let title, let items):
                        evidenceInspector(title: title, items: items)
                    case .archiveDay(let day):
                        archiveDayInspector(day)
                    case .durableMemory(let memory):
                        durableMemoryInspector(memory)
                    case .reflection(let letter):
                        reflectionInspector(letter)
                    }
                } else {
                    VStack(spacing: density.spacing(AppSpacing.sm)) {
                        RiverIconWell(systemImage: "sidebar.trailing", tint: AppTheme.neutral, size: 34)
                        Text("选择一条记录查看详情")
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.tertiaryInk)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.sidebarSurface)
    }

    private var inspectorHeader: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondaryInk)
            Text("证据详情")
                .font(AppTypography.rowTitle().weight(.semibold))
                .foregroundStyle(Color.ink)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .iconAction()
            .accessibilityLabel("关闭证据详情")
            .help("关闭详情（Esc）")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, AppSpacing.panelPadding)
        .padding(.vertical, AppSpacing.md)
        .frame(minHeight: 44)
        .background(Color.sidebarSurface)
        .overlay(alignment: .bottom) { RiverRule() }
    }

    // MARK: Episode

    /// 碎片带不是一个可以整理的证据：它是展示层的聚合，只有它的成员各自有标注键。
    /// 与其给一个按下去没有反应的"编辑"，不如说清它是什么、节奏如何、要去哪里看。
    private func fragmentRunNote(_ item: ActivityTimelineItem) -> some View {
        let spans = item.fragments.map(\.span)
        let average = spans.isEmpty ? 0 : spans.reduce(0, +) / Double(spans.count)
        let shortest = spans.min() ?? 0
        let shape = FragmentRunShape.classify(item)
        var lines: [String] = ["这 \(item.fragments.count) 段记录都不到 3 分钟，在时间线里折成了一条。"]
        if let phrase = shape.phrase { lines.append("\(phrase)。") }
        if average > 0 {
            lines.append("平均每段 \(ActivityFormatter.time(average))，最短 \(ActivityFormatter.time(shortest))。")
        }
        lines.append("展开这一行可以逐条查看，每一段都能单独整理。")
        return section("碎片带") {
            Text(lines.joined())
                .font(AppTypography.secondary())
                .foregroundStyle(Color.secondaryInk)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func episodeInspector(_ item: ActivityTimelineItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.panelGap)) {
                VStack(alignment: .leading, spacing: density.spacing(5)) {
                    Text(item.title)
                        .font(AppTypography.sheetTitle())
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: density.spacing(AppSpacing.sm)) {
                        Text(clockRange(item))
                        if item.duration > 0 { Text(ActivityFormatter.time(item.duration)) }
                    }
                    .font(AppTypography.numeric())
                    .foregroundStyle(Color.secondaryInk)
                }

                if isEditing {
                    editor(item)
                } else {
                    if item.isFragmentRun {
                        fragmentRunNote(item)
                    }
                    section("摘要") {
                        Text(item.summary)
                            .font(AppTypography.secondary())
                            .foregroundStyle(Color.secondaryInk)
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                        if let note = item.annotation?.note, !note.isEmpty {
                            Text(note)
                                .font(AppTypography.secondary())
                                .foregroundStyle(Color.secondaryInk)
                                .lineSpacing(5)
                                .padding(.top, density.spacing(AppSpacing.xs))
                        }
                        if let place = item.annotation?.normalized.placeName, !place.isEmpty {
                            Label("地点：\(place)", systemImage: "mappin.and.ellipse")
                                .font(AppTypography.metadata())
                                .foregroundStyle(AppTheme.accent)
                        }
                        if let activity = item.annotation?.normalized.activityLabel, !activity.isEmpty {
                            Label("人工判断：\(activity)", systemImage: "tag")
                                .font(AppTypography.metadata())
                                .foregroundStyle(AppTheme.accent)
                        }
                        if item.annotation?.isReviewed == true {
                            Label("已确认这条证据", systemImage: "checkmark.seal.fill")
                                .font(AppTypography.metadata())
                                .foregroundStyle(AppTheme.ok)
                        }
                    }
                    section("为什么这样说") {
                        Text(explanationText(for: item))
                            .font(AppTypography.secondary())
                            .foregroundStyle(Color.secondaryInk)
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                section("依据") {
                    VStack(alignment: .leading, spacing: density.spacing(6)) {
                        ForEach(item.sessions, id: \.id) { session in
                            EvidenceRow(session: session)
                        }
                        if item.kind == .capture, let capture = item.capture {
                            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
                                HStack(alignment: .firstTextBaseline, spacing: density.spacing(AppSpacing.sm)) {
                                    Text(capture.createdAt.formatted(date: .omitted, time: .shortened))
                                        .font(AppTypography.metadata().monospacedDigit())
                                        .foregroundStyle(Color.secondaryInk)
                                        .frame(width: 46, alignment: .leading)
                                    Text(capture.text)
                                        .font(AppTypography.secondary())
                                        .foregroundStyle(Color.ink)
                                }
                                HStack(spacing: density.spacing(AppSpacing.md)) {
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(capture.text, forType: .string)
                                    } label: {
                                        Label("复制", systemImage: "doc.on.doc")
                                    }
                                    .buttonStyle(.plain)
                                    .smallAction()
                                    Button(role: .destructive) {
                                        captureToDelete = capture
                                    } label: {
                                        Label("删除快记", systemImage: "trash")
                                    }
                                    .buttonStyle(.plain)
                                    .smallAction()
                                }
                            }
                            .padding(.vertical, density.spacing(AppSpacing.xs))
                        }
                    }
                }

                section("依据细度") {
                    confidenceBadge(for: item)
                }

                HStack(spacing: density.spacing(AppSpacing.sm)) {
                    if isEditing {
                        Button("取消") { isEditing = false }
                            .buttonStyle(.plain)
                            .smallAction()
                        Button("保存整理") { toggleEditing(item) }
                            .primaryCTA()
                    } else {
                        // 只有真实的活动块能整理。空档、快记、碎片带没有标注键，
                        // 那个"编辑"按下去既不会保存也不会报错。
                        if item.isAnnotatable {
                            Button("编辑") { toggleEditing(item) }
                                .buttonStyle(.plain)
                                .smallAction(dark: true)
                        }
                        if item.annotation != nil {
                            Button("清除整理") {
                                if let key = item.annotationKey {
                                    do {
                                        try store.saveTimelineAnnotation(TimelineAnnotation(), for: key)
                                        notify("已清除这次整理的标注")
                                    } catch {
                                        notify("清除失败：\(UserFacingError.message(for: error))")
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .smallAction()
                        }
                    }
                    Spacer(minLength: 0)
                }

                if let feedback {
                    Text(feedback)
                        .font(AppTypography.metadata())
                        .foregroundStyle(feedback.hasPrefix("失败") ? AppTheme.error : Color.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.panelPadding)
        }
        .riverScrollIndicators()
        .onAppear { resetEditingIfNecessary(for: item) }
        // .episode(A)→.episode(B) 是同一分支、结构身份不变，onAppear 不会重触发；
        // 编辑草稿必须在节点变化时丢弃，否则 A 的标注会被保存进 B。
        .onChange(of: item.id) { _, _ in resetEditingIfNecessary(for: item) }
        .confirmationDialog(
            "删除这条快记？",
            isPresented: Binding(
                get: { captureToDelete != nil },
                set: { if !$0 { captureToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let capture = captureToDelete {
                    deleteCapture(capture)
                }
                captureToDelete = nil
            }
            Button("取消", role: .cancel) { captureToDelete = nil }
        }
    }

    private func deleteCapture(_ capture: QuickCapture) {
        let entry = store.entry(for: capture.createdAt)
        store.removeQuickCapture(capture, entry: entry)
        switch store.saveState {
        case .failed(let message):
            notify("删除失败：\(message)")
        default:
            notify("已删除这条快记")
        }
    }

    private func notify(_ message: String) {
        feedback = message
        feedbackCenter.show(message, kind: message.contains("失败") ? .error : .success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if self.feedback == message { self.feedback = nil }
        }
    }

    /// 节点切换或面板重新出现时丢弃上一节点的编辑草稿。
    /// `editingItemID` 记录草稿属于哪个节点；同节点保持草稿（不丢用户输入）。
    @State private var editingItemID: String?

    private func resetEditingIfNecessary(for item: ActivityTimelineItem) {
        guard editingItemID != item.id else { return }
        editingItemID = item.id
        isEditing = false
        editingTitle = ""
        editingNote = ""
        editingPlaceName = ""
        editingActivityLabel = ""
        editingFavorite = false
        editingReviewed = false
    }

    private func toggleEditing(_ item: ActivityTimelineItem) {
        if isEditing {
            if let key = item.annotationKey {
                var annotation = store.timelineAnnotations[key] ?? TimelineAnnotation()
                annotation.title = editingTitle
                annotation.note = editingNote
                annotation.placeName = editingPlaceName
                annotation.activityLabel = editingActivityLabel
                annotation.isFavorite = editingFavorite
                annotation.isReviewed = editingReviewed
                annotation.reviewedAt = editingReviewed ? Date() : nil
                do {
                    try store.saveTimelineAnnotation(annotation, for: key)
                    notify("已保存整理")
                } catch {
                    notify("保存失败：\(UserFacingError.message(for: error))")
                }
            }
            isEditing = false
        } else {
            editingTitle = item.annotation?.title ?? ""
            editingNote = item.annotation?.note ?? ""
            editingPlaceName = item.annotation?.placeName ?? ""
            editingActivityLabel = item.annotation?.activityLabel ?? ""
            editingFavorite = item.annotation?.isFavorite ?? false
            editingReviewed = item.annotation?.isReviewed ?? false
            editingItemID = item.id
            isEditing = true
        }
    }

    private func editor(_ item: ActivityTimelineItem) -> some View {
        VStack(alignment: .leading, spacing: density.spacing(10)) {
            TextField("标题", text: $editingTitle)
                .textFieldStyle(.roundedBorder)
            TextField("地点，如图书馆", text: $editingPlaceName)
                .textFieldStyle(.roundedBorder)
            suggestionRow(
                title: "常用地点",
                values: ["家", "学校", "图书馆", "咖啡馆", "办公室"],
                selection: $editingPlaceName
            )
            TextField("活动，如学习 / 工作", text: $editingActivityLabel)
                .textFieldStyle(.roundedBorder)
            suggestionRow(
                title: "活动标签",
                values: ["学习", "工作", "娱乐", "沟通", "通勤"],
                selection: $editingActivityLabel
            )
            TextEditor(text: $editingNote)
                .font(AppTypography.secondary())
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(AppSpacing.sm)
                .background(Color.editor, in: RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                        .strokeBorder(Color.border, lineWidth: 1)
                )
            Toggle("收藏", isOn: $editingFavorite)
                .font(AppTypography.secondary())
            Toggle("我已确认这条证据", isOn: $editingReviewed)
                .font(AppTypography.secondary())
        }
    }

    private func suggestionRow(title: String, values: [String], selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: density.spacing(5)) {
            RiverGroupLabel(text: title)
            ChipFlow(spacing: AppSpacing.xs) {
                ForEach(values, id: \.self) { value in
                    FilterChip(title: value, isSelected: selection.wrappedValue == value) {
                        selection.wrappedValue = value
                    }
                }
            }
        }
    }

    private func confidenceBadge(for item: ActivityTimelineItem) -> some View {
        let titled = item.sessions.filter { !($0.windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let description: String
        if item.kind == .capture {
            description = "这是你写下的快记，时间表示记录时刻。"
        } else if item.kind == .gap {
            description = "这里没有实时片段；未记录不代表没有发生。"
        } else if !hasAnnotationText(item) {
            if item.sessions.isEmpty {
                description = "没有可读取的原始活动片段。"
            } else if titled == item.sessions.count {
                description = "包含应用名和窗口标题；这些信息仍不能证明完成了什么。"
            } else if titled > 0 {
                description = "部分片段包含窗口标题，其余只有应用名。"
            } else {
                description = "只有应用名和时长，无法得知具体目标。"
            }
        } else {
            description = "包含你添加的标题、活动或地点说明；原始片段仍可在下方核对。"
        }
        return Text(description)
            .font(AppTypography.metadata())
            .foregroundStyle(Color.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func hasAnnotationText(_ item: ActivityTimelineItem) -> Bool {
        guard let annotation = item.annotation?.normalized else { return false }
        return !annotation.title.isEmpty || !annotation.note.isEmpty
            || !annotation.placeName.isEmpty || !annotation.activityLabel.isEmpty
    }

    private func explanationText(for item: ActivityTimelineItem) -> String {
        if item.kind == .capture {
            return "这句话由你手动留下，时间线记录的是写下它的时刻。"
        }
        if item.kind == .gap {
            return "这段时间没有实时片段。应用不会把空白解释成休息或未工作。"
        }
        if item.isFragmentRun {
            return "这是一组短片段的展示折叠。展开后能逐条查看；折叠不会改变时长和来源记录。"
        }
        if hasAnnotationText(item) {
            return "标题、地点或活动说明来自你的人工整理。下方保留自动记录，便于核对和修改。"
        }
        let appNames = item.apps.prefix(2).map(\.name).joined(separator: "、")
        if item.sessions.contains(where: { !($0.windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "系统记录到前台应用\(appNames.isEmpty ? "" : " \(appNames)")及窗口标题。标题说明屏幕上显示的内容，不自动证明完成了某项工作。"
        }
        return "系统只记录到前台应用\(appNames.isEmpty ? "" : " \(appNames)")和时长；具体做了什么仍未知。"
    }

    // MARK: Evidence

    private func evidenceInspector(title: String, items: [AskEvidence]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.panelGap)) {
                Text(title)
                    .font(AppTypography.sheetTitle())
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                section("回答依据 · \(items.count) 个来源") {
                    VStack(spacing: 0) {
                        ForEach(Array(items.prefix(20).enumerated()), id: \.element.id) { index, item in
                            VStack(alignment: .leading, spacing: density.spacing(3)) {
                                HStack(spacing: density.spacing(AppSpacing.sm)) {
                                    Text(item.kind.rawValue)
                                        .font(AppTypography.micro().weight(.semibold))
                                        .foregroundStyle(AppTheme.accent)
                                        .padding(.horizontal, density.spacing(6))
                                        .padding(.vertical, density.spacing(AppSpacing.xxs))
                                        .background(AppTheme.accentSoft, in: Capsule())
                                    Text(item.title)
                                        .font(AppTypography.metadata().monospacedDigit())
                                        .foregroundStyle(Color.secondaryInk)
                                }
                                Text(item.detail)
                                    .font(AppTypography.secondary())
                                    .foregroundStyle(Color.ink)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, density.spacing(6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if !item.episodes.isEmpty {
                                VStack(alignment: .leading, spacing: density.spacing(3)) {
                                    RiverGroupLabel(text: "来源片段")
                                    ForEach(item.episodes) { episode in
                                        Text("· \(episode.title) · \(episode.startTime.formatted(date: .abbreviated, time: .shortened))")
                                            .font(AppTypography.metadata())
                                            .foregroundStyle(Color.secondaryInk)
                                    }
                                }
                                .padding(.leading, density.spacing(10))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if index < min(items.count, 20) - 1 { RiverRowDivider(inset: 0) }
                        }
                    }
                    if items.isEmpty {
                        EmptyStateView(
                            title: "没有可展示的依据。",
                            message: "打开一段时间线节点后，它引用的原始记录会出现在这里。",
                            symbol: "link",
                            showsChrome: false
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.panelPadding)
        }
        .riverScrollIndicators()
    }

    private func archiveDayInspector(_ day: MemoryArchiveDay) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.panelGap)) {
                Text(day.entry.shortDate)
                    .font(AppTypography.pageTitle())
                    .foregroundStyle(Color.ink)
                if !day.entry.displayOverview.isEmpty {
                    section("日记") {
                        Text(day.entry.displayOverview)
                            .font(AppTypography.secondary())
                            .foregroundStyle(Color.secondaryInk)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !day.captures.isEmpty {
                    section("快记") {
                        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
                            ForEach(day.captures) { capture in
                                Text(capture.text)
                                    .font(AppTypography.primary())
                                    .foregroundStyle(Color.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                HStack {
                    Text("来源：日期档案")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.tertiaryInk)
                    Spacer()
                    Button("在 Today 打开") {
                        NotificationCenter.default.post(name: .riverCommand, object: nil, userInfo: ["value": "goDate", "date": day.id])
                    }
                    .buttonStyle(.plain)
                    .smallAction()
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.panelPadding)
        }
        .riverScrollIndicators()
    }

    private func durableMemoryInspector(_ memory: Memory) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.panelGap)) {
                VStack(alignment: .leading, spacing: density.spacing(5)) {
                    Text(memory.title)
                        .font(AppTypography.pageTitle())
                        .foregroundStyle(Color.ink)
                    Text(memory.kind.displayName)
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.secondaryInk)
                }
                if !memory.body.isEmpty {
                    Text(memory.body)
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.secondaryInk)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: density.spacing(AppSpacing.sm)) {
                    Text("置信度 \(memory.confidence)")
                        .font(AppTypography.numeric())
                        .foregroundStyle(Color.ink)
                    StatusBadge(
                        library.confirmations[memory.id.uuidString]?.confirmed == true ? "已确认" : "待确认",
                        tone: library.confirmations[memory.id.uuidString]?.confirmed == true ? .positive : .neutral
                    )
                    Spacer(minLength: 0)
                    Button("确认") {
                        if library.setConfirmation(for: memory, confirmed: true) {
                            notify("已确认这条长期记忆")
                        } else {
                            notify("确认失败：无法写入本地状态")
                        }
                    }
                    .buttonStyle(.plain)
                    .smallAction(dark: true)
                    Button("不准确") {
                        if library.setConfirmation(for: memory, confirmed: false, note: "用户标记为不准确") {
                            notify("已标记为不准确")
                        } else {
                            notify("标记失败：无法写入本地状态")
                        }
                    }
                    .buttonStyle(.plain)
                    .smallAction()
                }
                if let episodes = library.sourceEpisodes[memory.id.uuidString], !episodes.isEmpty {
                    section("来源片段") {
                        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
                            ForEach(episodes) { episode in
                                VStack(alignment: .leading, spacing: density.spacing(3)) {
                                    Text(episode.title)
                                        .font(AppTypography.rowTitle())
                                        .foregroundStyle(Color.ink)
                                    Text(episode.summary)
                                        .font(AppTypography.secondary())
                                        .foregroundStyle(Color.secondaryInk)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.panelPadding)
        }
        .riverScrollIndicators()
    }

    private func reflectionInspector(_ letter: MonthlyLetter) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.panelGap)) {
                Text(letter.title)
                    .font(AppTypography.pageTitle())
                    .foregroundStyle(Color.ink)
                Text(letter.body)
                    .font(AppTypography.secondary())
                    .foregroundStyle(Color.secondaryInk)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                section("依据") {
                    Text(letter.evidence)
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("保存于 \(letter.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.tertiaryInk)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.panelPadding)
        }
        .riverScrollIndicators()
    }

    /// One evidence block inside the inspector: the same panel as everywhere else.
    private func section<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        RiverPanel(title: title, padding: AppSpacing.md) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func clockRange(_ item: ActivityTimelineItem) -> String {
        ActivityFormatter.timeRange(item.start, item.end).replacingOccurrences(of: "–", with: " — ")
    }
}

private struct EvidenceRow: View {
    let session: ActivitySession

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xxs)) {
            HStack(spacing: density.spacing(AppSpacing.sm)) {
                Text(session.start.formatted(date: .omitted, time: .shortened))
                    .font(AppTypography.metadata().monospacedDigit())
                    .foregroundStyle(Color.secondaryInk)
                    .frame(width: 46, alignment: .leading)
                Text(session.appName)
                    .font(AppTypography.label().weight(.medium))
                    .foregroundStyle(Color.ink)
            }
            if let title = session.windowTitle, !title.isEmpty {
                Text(title)
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.secondaryInk)
                    .padding(.leading, TimelineRowMetrics.timeColumn)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, density.spacing(AppSpacing.xxs))
    }

    @Environment(\.riverDensity) private var density
}
