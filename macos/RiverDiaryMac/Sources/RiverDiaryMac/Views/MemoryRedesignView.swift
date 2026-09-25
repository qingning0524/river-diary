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

    @AppStorage("memory.query") private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var scope: MemoryScope = .all
    @State private var showsReview = false

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
        MemoryPresentation.durableMemories(library.durableMemories, query: memoryNeedle)
    }

    private var filteredReflections: [MonthlyLetter] {
        MemoryPresentation.reflections(library.savedReflections, scope: scope, query: memoryNeedle)
    }

    private var filteredArchiveDays: [MemoryArchiveDay] {
        MemoryPresentation.archiveDays(library.archiveDays, scope: scope, favoriteDates: favoriteDates, query: memoryNeedle)
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
        .onAppear { refreshLibrary() }
        .onChange(of: store.entries.count) { _, _ in refreshLibrary() }
        .onChange(of: store.quickCaptures.count) { _, _ in refreshLibrary() }
        .onChange(of: store.monthlyLetters.count) { _, _ in refreshLibrary() }
    }

    private func refreshLibrary() {
        library.refresh(entries: store.entries, captures: store.quickCaptures, letters: store.monthlyLetters)
    }

    private var unifiedHeader: some View {
        RiverHeaderBand {
            PageHeader("记忆", context: "从一个入口浏览长期记忆、回顾和日期档案。")
            HStack(spacing: density.spacing(AppSpacing.md)) {
                searchField
                Spacer(minLength: 0)
                Picker("范围", selection: $scope) {
                    ForEach(MemoryScope.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 380)
            }
        }
    }

    private var searchField: some View {
        RiverSearchField(
            placeholder: "搜索你的过去…",
            text: $query,
            focus: $searchFocused
        )
        .frame(maxWidth: 420)
    }

    private var unifiedLibrary: some View {
        RiverPageBody(spacing: AppSpacing.sectionGap, lazy: true) {
            if showsReview {
                reviewCard
                    .riverAppear(index: 0)
            }
            ForEach(Array(MemoryPresentation.sections(for: scope).enumerated()), id: \.element) { index, section in
                Group {
                    switch section {
                    case .durable: durableSection
                    case .reflections: reflectionSection
                    case .archive: archiveSection
                    }
                }
                .riverAppear(index: index + 1)
            }
        }
    }

    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.md)) {
            HStack(alignment: .firstTextBaseline) {
                RiverSectionHeading(title: "周期回顾", detail: "把这段时间整理成一条可回看的线索")
                Spacer()
                Button("收起") { showsReview = false }
                    .buttonStyle(.plain)
                    .smallAction()
            }
            RiverPanel {
                ReviewContentView(store: store, activity: activity, ai: ai, library: library, selectedDate: selectedDate, showsHeader: false)
            }
        }
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
                    VStack(spacing: 0) {
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
                Button(showsReview ? "收起周期回顾" : "打开周期回顾") { showsReview.toggle() }
                    .buttonStyle(.plain)
                    .smallAction(dark: !showsReview)
            }
            if filteredReflections.isEmpty {
                RiverPanel { RiverInsetPanel(symbol: "text.book.closed", title: scope == .favorites ? "还没有收藏的回顾" : "还没有保存的回顾", message: "打开周期回顾，生成并保存一封河流信。") }
            } else {
                RiverPanel {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredReflections.enumerated()), id: \.element.id) { index, letter in
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
                            .onTapGesture { onInspectReflection(letter) }
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
                RiverPanel { RiverInsetPanel(symbol: "calendar", title: scope == .favorites ? "还没有收藏的日期" : "没有匹配的日期", message: memoryNeedle.isEmpty ? "写下日记或快记后，这里会保留每天的原始记录。" : "换个关键词试试看。") }
            } else {
                RiverPanel {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredArchiveDays.enumerated()), id: \.element.id) { index, day in
                            Button { onInspectArchive(day) } label: {
                                HStack(spacing: density.spacing(AppSpacing.md)) {
                                    Text(day.entry.shortDate)
                                        .font(AppTypography.numeric())
                                        .foregroundStyle(Color.secondaryInk)
                                        .frame(width: 58, alignment: .leading)
                                    Text(day.preview)
                                        .font(AppTypography.secondary())
                                        .foregroundStyle(Color.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: density.spacing(AppSpacing.sm))
                                    if favoriteDates.contains(day.id) {
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(AppTheme.warning)
                                    }
                                    Text(day.hasWriting ? "日记" : "快记")
                                        .font(AppTypography.metadata())
                                        .foregroundStyle(Color.tertiaryInk)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color.tertiaryInk)
                                }
                                .padding(.vertical, density.spacing(8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .bottom) {
                                if index < filteredArchiveDays.count - 1 { RiverRowDivider(inset: 0) }
                            }
                        }
                    }
                }
            }
        }
    }
}
