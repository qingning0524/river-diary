import SwiftUI

/// A single memory browser. Search, scope and details all stay in one flow;
/// the shell inspector owns the deep view instead of opening another app shell.
struct MemoryRedesignView: View {
    @Environment(\.riverDensity) private var density
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var library: MemoryLibraryStore
    let selectedDate: Date
    var onInspectArchive: (MemoryArchiveDay) -> Void = { _ in }
    var onInspectMemory: (Memory) -> Void = { _ in }
    var onInspectReflection: (MonthlyLetter) -> Void = { _ in }
    var onRevealEvidence: (String, [AskEvidence]) -> Void = { _, _ in }

    /// 输入框的实时文本。搜索不直接绑定它：每击键都写 UserDefaults 并全量重扫
    /// 三个分区，代价太高——真正参与筛选的是防抖后的 appliedNeedle。
    @State private var query = ""
    /// 防抖后的搜索词；筛选与持久化都以它为准。
    @State private var appliedNeedle = ""
    private static let persistedQueryKey = "memory.query"

    @FocusState private var searchFocused: Bool
    @State private var scope: MemoryScope = .all
    var onOpenReview: () -> Void = {}
    var onWriteNote: () -> Void = {}

    private var memoryNeedle: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var favoriteDates: Set<String> {
        let favoredKeys = store.timelineAnnotations.filter { $0.value.isFavorite }
        return Set(favoredKeys.map(\.key).compactMap { key -> String? in
            guard let first = key.split(separator: "|").first,
                  let timestamp = Int64(first) else { return nil }
            return DiaryEntry.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        })
    }

    private var filteredDurableMemories: [Memory] {
        MemoryPresentation.durableMemories(library.durableMemories, query: appliedNeedle)
    }

    private var filteredReflections: [MonthlyLetter] {
        MemoryPresentation.reflections(library.savedReflections, scope: scope, query: appliedNeedle)
    }

    private var filteredArchiveDays: [MemoryArchiveDay] {
        MemoryPresentation.archiveDays(library.archiveDays, scope: scope, favoriteDates: favoriteDates, query: appliedNeedle)
    }

    var body: some View {
        VStack(spacing: 0) {
            unifiedHeader
            unifiedLibrary
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            Button("聚焦记忆搜索") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onAppear {
            if query.isEmpty {
                query = UserDefaults.standard.string(forKey: Self.persistedQueryKey) ?? ""
                appliedNeedle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            refreshLibrary()
        }
        .task(id: memoryNeedle) {
            guard memoryNeedle != appliedNeedle else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            appliedNeedle = memoryNeedle
            UserDefaults.standard.set(query, forKey: Self.persistedQueryKey)
        }
        .onChange(of: store.entries.count) { _, _ in refreshLibrary() }
        .onChange(of: store.quickCaptures.values.reduce(0) { $0 + $1.count }) { _, _ in refreshLibrary() }
        .onChange(of: store.monthlyLetters.count) { _, _ in refreshLibrary() }
    }

    private func refreshLibrary() {
        library.refresh(entries: store.entries, captures: store.quickCaptures, letters: store.monthlyLetters)
    }

    private var unifiedHeader: some View {
        RiverHeaderBand {
            PageHeader("记忆", context: "按日期回看，或搜索文字、片刻与亲自确认的记忆。")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    searchField
                    Spacer(minLength: 0)
                    memoryScopePicker
                }
                VStack(alignment: .leading, spacing: 15) {
                    searchField
                    memoryScopePicker
                }
            }
        }
    }

    private var memoryScopePicker: some View {
        RiverSegmentedPicker(title: "范围", selection: $scope,
                             options: Array(MemoryScope.allCases), label: { $0.title })
    }

    private var searchField: some View {
        RiverSearchField(
            placeholder: "搜索你的过去…",
            text: $query,
            focus: $searchFocused
        )
        .frame(maxWidth: 420)
    }

    private var hasVisibleResults: Bool {
        MemoryPresentation.sections(for: scope).contains { section in
            switch section {
            case .durable: !filteredDurableMemories.isEmpty
            case .reflections: !filteredReflections.isEmpty
            case .archive: !filteredArchiveDays.isEmpty
            }
        }
    }

    private var unifiedLibrary: some View {
        RiverPageBody(spacing: AppSpacing.sectionGap, lazy: true) {
            if !hasVisibleResults {
                libraryEmptyState
            } else {
                ForEach(Array(MemoryPresentation.sections(for: scope).enumerated()), id: \.element) { index, section in
                    Group {
                        switch section {
                        case .durable: if !filteredDurableMemories.isEmpty { durableSection }
                        case .reflections: if !filteredReflections.isEmpty { reflectionSection }
                        case .archive: if !filteredArchiveDays.isEmpty { archiveSection }
                        }
                    }.riverAppear(index: index)
                }
            }
        }
    }

    private var libraryEmptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: appliedNeedle.isEmpty ? "square.stack" : "magnifyingglass")
                .font(.system(size: 25, weight: .light)).foregroundStyle(AppTheme.accent).accessibilityHidden(true)
            Text(appliedNeedle.isEmpty ? (scope == .favorites ? "还没有收藏的片刻" : "记忆会从记录里慢慢沉淀") : "没有找到匹配的记忆")
                .font(AppTypography.sheetTitle()).foregroundStyle(Color.ink)
            Text(appliedNeedle.isEmpty
                 ? (scope == .favorites ? "在时间线或回顾里收藏值得留下的内容，之后可以在这里找到。" : "写下一段手记，或先看看已经记录的生活。")
                 : "试着换一个关键词，或清除搜索查看全部记录。")
                .font(AppTypography.secondary()).foregroundStyle(Color.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            if !appliedNeedle.isEmpty {
                Button("清除搜索") { query = ""; appliedNeedle = "" }.secondaryCTA()
            } else if scope == .all || scope == .archive {
                Button("写一笔", action: onWriteNote).primaryCTA()
            } else if scope == .reflections {
                Button("打开回顾", action: onOpenReview).secondaryCTA()
            }
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading).riverSoftSurface()
    }

    private var durableSection: some View {
        VStack(alignment: .leading, spacing: density.spacing(10)) {
            HStack(alignment: .firstTextBaseline) {
                RiverSectionHeading(title: "长期记忆", detail: "跨时间沉淀的主题与轨迹")
                Spacer()
                Text("\(filteredDurableMemories.count) 条")
                    .font(AppTypography.numeric())
                    .foregroundStyle(Color.tertiaryInk)
            }
            if filteredDurableMemories.isEmpty {
                RiverPanel { RiverInsetPanel(symbol: "brain.head.profile", title: "还没有长期记忆", message: "当足迹被整理成习惯、项目轨迹或长期主题后，会出现在这里。") }
            } else {
                RiverPanel {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredDurableMemories.enumerated()), id: \.element.id) { index, memory in
                            durableRow(memory, showsDivider: index < filteredDurableMemories.count - 1)
                        }
                    }
                }
            }
        }
    }

    private func durableRow(_ memory: Memory, showsDivider: Bool) -> some View {
        let confirmed = library.confirmations[memory.id.uuidString]?.confirmed == true
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: density.spacing(AppSpacing.md)) {
                RiverIconWell(systemImage: "brain.head.profile", tint: AppTheme.accent, size: 26)
                VStack(alignment: .leading, spacing: density.spacing(5)) {
                    HStack(spacing: density.spacing(AppSpacing.sm)) {
                        Text(memory.title)
                            .font(AppTypography.rowTitle())
                            .foregroundStyle(Color.ink)
                        Text(memory.kind.displayName)
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.tertiaryInk)
                        Spacer(minLength: 0)
                        Text("置信度 \(memory.confidence)")
                            .font(AppTypography.numeric())
                            .foregroundStyle(Color.tertiaryInk)
                    }
                    if !memory.body.isEmpty {
                        Text(memory.body)
                            .font(AppTypography.secondary())
                            .foregroundStyle(Color.secondaryInk)
                            .lineSpacing(4)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: density.spacing(AppSpacing.sm)) {
                        StatusBadge(confirmed ? "已确认" : "待确认", tone: confirmed ? .positive : .neutral)
                        Text("来源 \(library.sourceEpisodes[memory.id.uuidString]?.count ?? memory.sourceEpisodeIDs.count) 个片段")
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.tertiaryInk)
                    }
                }
                Spacer(minLength: 0)
                Button("查看") { onInspectMemory(memory) }
                    .buttonStyle(.plain)
                    .smallAction()
            }
            .padding(.vertical, density.spacing(10))

            if showsDivider { RiverRowDivider(inset: 0) }
        }
        .contentShape(Rectangle())
    }

    private var reflectionSection: some View {
        VStack(alignment: .leading, spacing: density.spacing(10)) {
            HStack(alignment: .firstTextBaseline) {
                RiverSectionHeading(title: "回顾与河流信", detail: "周期阅读与保存过的文字")
                Spacer()
                Button("打开回顾", action: onOpenReview).secondaryCTA()
            }
            if filteredReflections.isEmpty {
                RiverPanel { RiverInsetPanel(symbol: "text.book.closed", title: scope == .favorites ? "还没有收藏的回顾" : "还没有保存的回顾", message: "打开回顾，生成并保存一封河流信。") }
            } else {
                RiverPanel {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredReflections.enumerated()), id: \.element.id) { index, letter in
                            Button { onInspectReflection(letter) } label: {
                                HStack(alignment: .top, spacing: density.spacing(10)) {
                                    RiverIconWell(
                                        systemImage: letter.isFavorite ? "star.fill" : "text.book.closed",
                                        tint: letter.isFavorite ? AppTheme.warning : AppTheme.accent,
                                        size: 26
                                    )
                                    VStack(alignment: .leading, spacing: density.spacing(4)) {
                                        Text(letter.title)
                                            .font(AppTypography.rowTitle())
                                            .foregroundStyle(Color.ink)
                                        Text(letter.body)
                                            .font(AppTypography.secondary())
                                            .foregroundStyle(Color.secondaryInk)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(letter.evidence)
                                            .font(AppTypography.metadata())
                                            .foregroundStyle(Color.tertiaryInk)
                                    }
                                    Spacer(minLength: 0)
                                    Text(letter.month)
                                        .font(AppTypography.numeric())
                                        .foregroundStyle(Color.tertiaryInk)
                                }
                                .padding(.vertical, density.spacing(10))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看回顾 \(letter.title)")
                            .overlay(alignment: .bottom) {
                                if index < filteredReflections.count - 1 { RiverRowDivider(inset: 0) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: density.spacing(10)) {
            RiverSectionHeading(title: "日期档案", detail: "按天浏览原始日记和快记")
            if filteredArchiveDays.isEmpty {
                RiverPanel { RiverInsetPanel(symbol: "calendar", title: scope == .favorites ? "还没有收藏的日期" : "没有匹配的日期", message: appliedNeedle.isEmpty ? "写下日记或快记后，这里会保留每天的原始记录。" : "换个关键词试试看。") }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 24, alignment: .top)], alignment: .leading, spacing: 24) {
                    ForEach(filteredArchiveDays) { day in
                        Button { onInspectArchive(day) } label: {
                            VStack(alignment: .leading, spacing: 17) {
                                HStack {
                                    Text(day.entry.shortDate).font(AppTypography.metadata()).foregroundStyle(Color.secondaryInk)
                                    Spacer(minLength: 0)
                                    StatusBadge(day.hasWriting ? "我的文字" : "生活片刻", tone: .neutral)
                                }
                                Image(systemName: day.hasWriting ? "square.and.pencil" : "book")
                                    .font(.system(size: 23)).foregroundStyle(AppTheme.accent).padding(.vertical, 6)
                                Text(String((day.entry.daily?.isEmpty == false ? day.entry.daily! : day.preview).prefix(30)))
                                    .font(AppTypography.sectionTitle()).foregroundStyle(Color.ink).lineLimit(3)
                                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
                                Text(day.entry.displayOverview)
                                    .font(AppTypography.metadata()).foregroundStyle(Color.secondaryInk)
                                    .lineSpacing(4).lineLimit(3).frame(minHeight: 52, alignment: .topLeading)
                                Rectangle().fill(Color.separator).frame(height: 1)
                                HStack {
                                    Text(day.hasWriting ? "自己的声音，随时回看" : "从原始片刻中回看")
                                        .font(AppTypography.micro()).foregroundStyle(Color.secondaryInk)
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(AppTheme.accent)
                                }
                            }
                            .padding(23).frame(maxWidth: .infinity, alignment: .leading)
                            .riverSoftSurface()
                            .contentShape(RoundedRectangle(cornerRadius: 24))
                        }.buttonStyle(.plain)
                        .accessibilityLabel("查看 \(day.entry.shortDate) 的档案")
                    }
                }
            }
        }
    }
}
