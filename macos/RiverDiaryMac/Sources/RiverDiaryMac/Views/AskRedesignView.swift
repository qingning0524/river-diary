import SwiftUI

struct AskRedesignView: View {
    @Environment(\.riverDensity) private var density
    @EnvironmentObject private var feedbackCenter: FeedbackCenter
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var library: MemoryLibraryStore
    @ObservedObject var location: LocationSourceStore
    @Binding var query: String
    var selectedDate: Date
    var savedQueries: [SavedQuery]
    var onOpenFootprints: () -> Void
    var onShowEvidence: (String, [AskEvidence]) -> Void

    @State private var answer: AskedAnswer?
    @FocusState private var searchFocused: Bool
    @State private var history: [AskedAnswer] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var aiEvidence: [AskEvidence] = []
    @State private var aiEvidenceQuery = ""

    private struct AskedAnswer: Identifiable {
        var id: String { "\(query)|\(Date().timeIntervalSince1970)" }
        let query: String
        let memory: MemoryAnswer
        let captures: [QuickCapture]
    }

    private var allCaptures: [QuickCapture] {
        store.quickCaptures.values.flatMap(\.self)
    }

    private var emptyAnswerIsLocationQuestion: Bool {
        guard let answer else { return false }
        return AskQuestionIntent.asksAboutKnownPlace(answer.query)
    }

    var body: some View {
        RiverPage(maxWidth: 760, topPadding: AppSpacing.sm) {
            header
                .riverAppear(index: 0)
            inputBar
                .riverAppear(index: 1)
            if let currentAnswer = answer,
               aiEvidenceQuery == currentAnswer.query,
               let aiAnswer = ai.state(for: .memorySearch)?.answer {
                aiAnswerView(aiAnswer)
                    .riverAppear(index: 2)
            }
            if let answer {
                answerView(answer)
                    .riverAppear(index: 2)
                recentQuestions
                    .riverAppear(index: 3)
            } else {
                suggestions
                    .riverAppear(index: 2)
                if !history.isEmpty {
                    recentQuestions
                        .riverAppear(index: 3)
                }
            }
            if !savedQueries.isEmpty {
                savedQueryRow
                    .riverAppear(index: 4)
            }
        }
        .overlay(alignment: .top) {
            Button("聚焦询问搜索") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onChange(of: selectedDate) { _, _ in
            searchTask?.cancel()
            answer = nil
            aiEvidence = []
            aiEvidenceQuery = ""
            isSearching = false
        }
    }

    private var header: some View {
        PageHeader("询问", context: "询问你的过去，答案会回到证据。")
    }

    private var inputBar: some View {
        RiverPanel(padding: AppSpacing.md) {
            HStack(spacing: density.spacing(AppSpacing.sm)) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.tertiaryInk)
                TextField("问问你的过去…", text: $query)
                    .textFieldStyle(.plain)
                    .font(AppTypography.secondary())
                    .focused($searchFocused)
                    .onSubmit(run)
                    .help("按 ⌘F 聚焦搜索")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.tertiaryInk)
                    }
                    .buttonStyle(.plain)
                    .help("清除")
                }
                Button(isSearching ? "查找中…" : "查找", action: run)
                    .primaryCTA()
                    .disabled(isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func aiAnswerView(_ answer: String) -> some View {
        RiverPanel(title: "AI 整理", systemImage: "sparkles", accent: AppTheme.accent, tint: AppTheme.accent) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
                Text(answer)
                    .font(AppTypography.secondary())
                    .foregroundStyle(Color.ink)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        onShowEvidence(aiEvidenceQuery, aiEvidence)
                    } label: {
                        Label("查看依据（\(aiEvidence.count)）", systemImage: "doc.on.doc")
                    }
                    .linkAction()
                    .font(AppTypography.metadata())
                    Spacer()
                }
            }
        }
    }

    private var suggestions: some View {
        RiverPanel(title: "建议提问", systemImage: "lightbulb", accent: AppTheme.neutral) {
            VStack(spacing: 0) {
                suggestionRow("今天做了什么？", icon: "sun.max")
                suggestionRow("上周主要做了什么？", icon: "calendar")
                suggestionRow("本月提到工作了吗？", icon: "briefcase")
                suggestionRow("哪天去了图书馆？", icon: "books.vertical")
                suggestionRow("哪天主要在学习？", icon: "graduationcap", showsDivider: false)
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        RiverGroupLabel(text: title)
    }

    private func suggestionRow(_ text: String, icon: String, showsDivider: Bool = true) -> some View {
        Button {
            query = text
            run()
        } label: {
            HStack(spacing: density.spacing(10)) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 16)
                Text(text)
                    .font(AppTypography.secondary())
                    .foregroundStyle(Color.ink)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.tertiaryInk)
            }
            .padding(.vertical, density.spacing(7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if showsDivider { RiverRowDivider(inset: 0) }
        }
    }

    private var savedQueryRow: some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
            HStack(alignment: .firstTextBaseline, spacing: density.spacing(AppSpacing.sm)) {
                sectionLabel("已保存查询")
                Text("\(savedQueries.count)")
                    .font(AppTypography.numeric())
                    .foregroundStyle(Color.tertiaryInk)
                Spacer()
            }

            ChipFlow(spacing: AppSpacing.sm) {
                ForEach(Array(savedQueries.prefix(10)), id: \.id) { saved in
                    Button {
                        query = saved.query
                        run()
                    } label: {
                        Label(saved.name, systemImage: "bookmark")
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.secondaryInk)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.chip, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(saved.rangeLabel)
                }
            }
        }
    }

    private var recentQuestions: some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
            sectionLabel("最近提问")
            ChipFlow(spacing: AppSpacing.sm) {
                ForEach(history.suffix(5).reversed(), id: \.id) { item in
                    Button {
                        query = item.query
                        run()
                    } label: {
                        Text(item.query)
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.secondaryInk)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.chip, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Run

    private func run() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        library.refresh(entries: store.entries, captures: store.quickCaptures, letters: store.monthlyLetters)
        // Snapshot the inputs on the main actor, then search off the main thread so a
        // large memory store never freezes the UI. Cancelling the task when a newer
        // query arrives makes typing/retriggering feel responsive.
        let entries = store.entries
        let captures = allCaptures
        isSearching = true
        searchTask?.cancel()
        let memories = library.durableMemories
        let reflections = library.savedReflections
        let sourceEpisodes = library.sourceEpisodes
        let timelineAnnotations = store.timelineAnnotations
        let sessions = activity.sessions
        let dailyGoals = store.dailyGoals
        searchTask = Task { @MainActor in
            let memory = await Task.detached(priority: .userInitiated) {
                MemorySearchEngine.search(
                    trimmed,
                    entries: entries,
                    quickCaptures: captures,
                    memories: memories,
                    reflections: reflections,
                    sourceEpisodes: sourceEpisodes,
                    timelineAnnotations: timelineAnnotations,
                    sessions: sessions,
                    referenceDate: selectedDate,
                    dailyGoals: dailyGoals
                )
            }.value
            guard !Task.isCancelled else { return }
            let result = AskedAnswer(query: trimmed, memory: memory, captures: captures)
            self.answer = result
            self.history.append(result)
            if self.history.count > 12 { self.history.removeFirst(self.history.count - 12) }
            self.isSearching = false
        }
    }

    // MARK: Answer

    @ViewBuilder
    private func answerView(_ answer: AskedAnswer) -> some View {
        let memory = answer.memory
        let entryCount = memory.entries.count
        let noteCount = memory.notes.count
        let durableCount = memory.memories.count
        let reflectionCount = memory.reflections.count
        let captureCount = answer.captures.filter { capture in
            memory.entries.contains { $0.date == DiaryEntry.dateFormatter.string(from: capture.createdAt) }
        }.count
        let evidence = evidenceItems(for: memory)
        let hasEvidence = !evidence.isEmpty

        RiverPanel(title: "答案", systemImage: "text.bubble", accent: AppTheme.accent) {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.lg)) {
            HStack(spacing: density.spacing(AppSpacing.sm)) {
                Spacer()
                if ai.hasVerifiedConnection {
                    Button {
                        let candidates = AskCandidateSet.make(from: memory)
                        aiEvidence = evidenceItems(for: candidates)
                        aiEvidenceQuery = answer.query
                        Task {
                            await ai.searchMemory(query: answer.query, candidateSet: candidates, sourceEpisodes: library.sourceEpisodes)
                        }
                    } label: {
                        Label(ai.state(for: .memorySearch)?.isLoading == true ? "整理中…" : "整理成 AI 回答", systemImage: "sparkles")
                            .font(AppTypography.metadata())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(ai.state(for: .memorySearch)?.isLoading == true)
                }
                Button {
                    saveQuery(answer.query)
                } label: {
                    Label("保存查询", systemImage: "bookmark")
                        .font(AppTypography.metadata())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(savedQueries.contains { $0.query == answer.query })
                Button {
                    answerReset()
                } label: {
                        Label("重新查找", systemImage: "arrow.clockwise")
                        .font(AppTypography.metadata())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !memory.usedFilters.isEmpty {
                HStack(spacing: density.spacing(AppSpacing.xs)) {
                    Text("已识别条件")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.tertiaryInk)
                    ForEach(memory.usedFilters, id: \.self) { filter in
                        Text(filter)
                            .font(AppTypography.metadata())
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(AppTheme.accentSoft, in: Capsule())
                    }
                }
            }

            if !hasEvidence {
                VStack(alignment: .leading, spacing: 8) {
                    EmptyStateView(
                        title: "没有找到相关记忆",
                        message: emptyAnswerIsLocationQuestion
                            ? locationEmptyMessage
                            : "没有证据能回答这个问题。换一种说法，或试试点击下面的已保存查询。",
                        actionTitle: emptyAnswerIsLocationQuestion ? "前往足迹" : "换一个问题",
                        action: emptyAnswerIsLocationQuestion ? onOpenFootprints : { answerReset() }
                    )
                    .font(AppTypography.secondary())
                    if emptyAnswerIsLocationQuestion {
                        Button("换一个问题", action: answerReset)
                            .buttonStyle(.plain)
                            .font(AppTypography.metadata())
                            .foregroundStyle(AppTheme.accent)
                    }
                }
            } else {
                Text(memory.summary.isEmpty ? "找到了与这个问题相关的记录。" : memory.summary)
                    .font(AppTypography.primary())
                    .foregroundStyle(Color.ink)
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: density.spacing(AppSpacing.md)) {
                    countStat("\(entryCount)", "天")
                    if noteCount > 0 { countStat("\(noteCount)", "篇笔记") }
                    if captureCount > 0 { countStat("\(captureCount)", "条快记") }
                    if durableCount > 0 { countStat("\(durableCount)", "条长期记忆") }
                    if reflectionCount > 0 { countStat("\(reflectionCount)", "封河流信") }
                }

                Button {
                    onShowEvidence(answer.query, evidence)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                        Text("基于 \(evidence.count) 个来源 · 查看依据")
                    }
                    .font(AppTypography.secondary())
                }
                .buttonStyle(.bordered)

                if !memory.entries.isEmpty {
                    evidenceBlock(title: "相关日记", symbol: "book.text") {
                        ForEach(Array(memory.entries.prefix(5)), id: \.id) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: density.spacing(10)) {
                                Text(entry.shortDate)
                                    .font(AppTypography.mono())
                                    .foregroundStyle(Color.secondaryInk)
                                    .frame(width: 60, alignment: .trailing)
                                Text(entry.displayOverview)
                                    .font(AppTypography.secondary())
                                    .foregroundStyle(Color.ink)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                if !memory.notes.isEmpty {
                    evidenceBlock(title: "证据片段", symbol: "quote.opening") {
                        ForEach(Array(memory.notes.prefix(8))) { note in
                            HStack(alignment: .firstTextBaseline, spacing: density.spacing(AppSpacing.sm)) {
                                Text(note.date)
                                    .font(AppTypography.mono())
                                    .foregroundStyle(Color.tertiaryInk)
                                    .frame(width: 70, alignment: .leading)
                                Text(note.text)
                                    .font(AppTypography.secondary())
                                    .foregroundStyle(Color.ink)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                if !memory.memories.isEmpty {
                    evidenceBlock(title: "长期记忆", symbol: "brain.head.profile") {
                        ForEach(memory.memories) { durable in
                            HStack(alignment: .firstTextBaseline, spacing: density.spacing(AppSpacing.sm)) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppTheme.accent)
                                Text(durable.title)
                                    .font(AppTypography.rowTitle())
                                    .foregroundStyle(Color.ink)
                                Spacer()
                                Text("置信度 \(durable.confidence)")
                                    .font(AppTypography.metadata())
                                    .foregroundStyle(Color.tertiaryInk)
                            }
                        }
                    }
                }
                if !memory.reflections.isEmpty {
                    evidenceBlock(title: "河流信", symbol: "envelope.open") {
                        ForEach(memory.reflections) { reflection in
                            VStack(alignment: .leading, spacing: density.spacing(3)) {
                                Text(reflection.title)
                                    .font(AppTypography.rowTitle())
                                    .foregroundStyle(Color.ink)
                                Text(reflection.body)
                                    .font(AppTypography.secondary())
                                    .foregroundStyle(Color.secondaryInk)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One labelled block of evidence inside the answer panel.
    private func evidenceBlock<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
            HStack(spacing: density.spacing(AppSpacing.xs)) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondaryInk)
                Text(title)
                    .font(AppTypography.metadata().weight(.semibold))
                    .foregroundStyle(Color.secondaryInk)
            }
            content()
        }
        .padding(density.spacing(AppSpacing.md))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.editor, in: RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
    }

    private func countStat(_ value: String, _ label: String) -> some View {
        HStack(spacing: density.spacing(AppSpacing.xs)) {
            Text(value)
                .font(AppTypography.numeric())
                .foregroundStyle(Color.ink)
            Text(label)
                .font(AppTypography.metadata())
                .foregroundStyle(Color.secondaryInk)
        }
    }

    private func evidenceItems(for memory: MemoryAnswer) -> [AskEvidence] {
        let candidates = AskCandidateSet(
            entries: memory.entries,
            captures: memory.matchedCaptures,
            memories: memory.memories,
            reflections: memory.reflections,
            manualNotes: memory.manualNotes
        )
        return evidenceItems(for: candidates)
    }

    private func evidenceItems(for candidates: AskCandidateSet) -> [AskEvidence] {
        var result: [AskEvidence] = []
        result += candidates.entries.map { entry in
            AskEvidence(id: "diary-\(entry.id)", kind: .diary, title: entry.shortDate, detail: entry.displayOverview, date: entry.entryDate, episodes: [])
        }
        result += candidates.captures.map { capture in
            AskEvidence(id: "capture-\(capture.id.uuidString)", kind: .capture, title: capture.createdAt.formatted(date: .abbreviated, time: .shortened), detail: capture.text, date: capture.createdAt, episodes: [])
        }
        result += candidates.memories.map { durable in
            AskEvidence(id: "memory-\(durable.id.uuidString)", kind: .memory, title: durable.title, detail: durable.body, date: durable.createdAt, episodes: library.sourceEpisodes[durable.id.uuidString] ?? [])
        }
        result += candidates.reflections.map { reflection in
            AskEvidence(id: "reflection-\(reflection.id)", kind: .reflection, title: reflection.title, detail: "\(reflection.body)\n\n依据：\(reflection.evidence)", date: reflection.updatedAt, episodes: [])
        }
        result += candidates.manualNotes.map { note in
            AskEvidence(
                id: note.id,
                kind: note.tags.contains("每日目标") ? .goal : .timeline,
                title: note.date,
                detail: note.text,
                date: DiaryEntry.dateFormatter.date(from: note.date),
                episodes: []
            )
        }
        return result
    }

    private func answerReset() {
        answer = nil
        query = ""
    }

    private func saveQuery(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !savedQueries.contains(where: { $0.query == trimmed }) else { return }
        let name = trimmed.count <= 16 ? trimmed : String(trimmed.prefix(16)) + "…"
        do {
            try store.saveSavedQuery(SavedQuery(name: name, query: trimmed, days: 30))
        } catch {
            feedbackCenter.show("保存查询失败：\(UserFacingError.message(for: error))", kind: .error)
        }
    }

    private var locationEmptyMessage: String {
        if location.isConnected || location.latestLocation != nil {
            return "已收到位置数据，但自动地点识别尚未接入记忆搜索。Ask 目前检索日记、快记和人工标注；可在时间线标注地点后再查，不会根据坐标猜地点。"
        }
        return "地点来源尚未连接。Ask 目前检索日记、快记和人工标注；可前往足迹按需连接位置，或在时间线手动标注地点后再查。没有证据时不会猜测。"
    }
}

// MARK: - Chip flow layout

struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if maxWidth.isFinite, x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            if x > 0 { x += spacing }
            x += size.width
            totalWidth = max(totalWidth, x)
            rowHeight = max(rowHeight, size.height)
        }
        let height = rowHeight > 0 ? y + rowHeight : y
        return CGSize(width: maxWidth.isFinite ? min(maxWidth, totalWidth) : totalWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if bounds.width > 0, x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
