import SwiftUI

enum MemorySection: String, CaseIterable, Identifiable {
    case archive
    case aiSearch
    case notes

    static let displayOrder: [MemorySection] = [.archive, .aiSearch, .notes]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .archive: "记忆库"
        case .aiSearch: "AI 搜索"
        case .notes: "随笔"
        }
    }

    var caption: String {
        switch self {
        case .archive: "按天浏览所有历史内容"
        case .aiSearch: "让 AI 根据你的问题找回回忆"
        case .notes: "保留随手写下的完整原文"
        }
    }
}

struct MemoryView: View {
    @ObservedObject var ai: AIAssistantStore
    let entries: [DiaryEntry]
    var quickCaptures: [QuickCapture] = []
    var assignedCaptures: [String: [QuickCapture]] = [:]
    @Binding var section: MemorySection
    var showsHeader: Bool = true
    let openDate: (Date) -> Void

    @State private var query = ""
    @State private var submittedQuery = ""
    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 14)]
    private var archiveEntries: [DiaryEntry] { entries.sorted { $0.date > $1.date } }

    var body: some View {
        Group {
            if section == .archive {
                MemoryArchiveView(entries: entries, captures: assignedCaptures, openDate: openDate)
            } else if section == .notes {
                NotesView(entries: entries, quickCaptures: quickCaptures, assignedCaptures: assignedCaptures, ai: ai, showsHeader: false) { date in
                    openDate(date)
                }
                .background(.clear)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        aiSearchSection
                    }
                    .frame(maxWidth: AppLayout.contentMaxWidth, alignment: .leading)
                    .padding(.top, 6)
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: AppLayout.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
    }

    private var aiSearchSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader {
                sectionHeader(title: "AI 搜索", caption: "用自然语言从你的历史里找答案")
            }

            SoftCard(padding: 15) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 11) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.riverAmethyst)

                        TextField("例如：哪几天很累？本月提到工作了吗？", text: $query)
                            .textFieldStyle(.plain)
                            .font(.ui(14))
                            .onSubmit(runAISearch)

                        if !query.isEmpty {
                            Button {
                                query = ""
                                submittedQuery = ""
                                ai.clearTask(.memorySearch)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }

                        Button("AI 搜索") { runAISearch() }
                            .font(.ui(13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(LinearGradient.river(), in: Capsule())
                            .buttonStyle(.softPress)
                            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ai.state(for: .memorySearch)?.isLoading == true)
                    }

                    HStack(spacing: 7) {
                        aiSuggestion("找疲惫的日子", query: "哪几天很累？")
                        aiSuggestion("找工作记录", query: "本月提到工作了吗？")
                        aiSuggestion("找低分日子", query: "低于40有哪几天？")
                        Spacer()
                    }

                    Divider().opacity(0.55)

                    HStack(spacing: 16) {
                        Label("搜索 \(archiveEntries.count) 天日记", systemImage: "archivebox")
                        Label("引用日期可直接打开", systemImage: "calendar.badge.clock")
                        Spacer()
                        Label("仅在点击搜索时请求 AI", systemImage: "lock.shield")
                    }
                    .font(.ui(11, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }

            if !submittedQuery.isEmpty {
                aiResultSection
            }
        }
    }

    @ViewBuilder
    private var aiResultSection: some View {
        if let state = ai.state(for: .memorySearch) {
            SoftCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("AI 搜索结果", systemImage: "sparkles")
                            .font(.headline)
                        Spacer()
                        if state.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("重新搜索") { runAISearch() }
                                .buttonStyle(.plain)
                                .smallAction()
                        }
                    }

                    if state.isLoading {
                        Text("正在从历史记录中寻找与“\(submittedQuery)”有关的日期和内容…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let error = state.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let answer = state.answer {
                        FormattedAIResult(text: answer, accentColor: Color.riverAmethyst)
                        dateReferenceCards(answer)
                        HStack {
                            Text("基于本机历史内容生成")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button("复制") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(answer, forType: .string)
                            }
                            .buttonStyle(.plain)
                            .smallAction()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dateReferenceCards(_ answer: String) -> some View {
        let references = AISearchDateReferenceParser.references(
            from: answer,
            entries: entries,
            quickCaptures: quickCaptures
        )
        if !references.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text("相关日期")
                    .font(.subheadline.weight(.semibold))
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(references) { reference in
                        Button {
                            if let date = DiaryEntry.dateFormatter.date(from: reference.date) {
                                openDate(date)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(reference.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.ink)
                                    Text(reference.source)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    if let score = reference.score {
                                        Text("\(score)")
                                            .font(.system(size: 16, weight: .bold, design: .rounded))
                                            .foregroundStyle(Color.riverAmethyst)
                                    }
                                }
                                Text(reference.detail)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondaryInk)
                                    .lineSpacing(4)
                                    .lineLimit(4)
                                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                                HStack {
                                    Text(reference.date)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(13)
                            .background(Color.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.border, lineWidth: 1))
                        }
                        .buttonStyle(.softPress)
                    }
                }
            }
        }
    }

    private func sectionHeader(title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Memory")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            Text(title)
                .font(.editorial(34))
                .foregroundStyle(Color.ink)
            Text(caption)
                .font(.ui(13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: AppLayout.contentMaxWidth, alignment: .leading)
    }

    private func runAISearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        query = trimmed
        submittedQuery = trimmed
        ai.clearTask(.memorySearch)
        Task { await ai.searchMemory(query: trimmed, entries: entries, quickCaptures: quickCaptures) }
    }

    private func aiSuggestion(_ label: String, query value: String) -> some View {
        Button {
            query = value
            runAISearch()
        } label: {
            Text(label)
                .font(.ui(12, weight: .medium))
                .foregroundStyle(Color.secondaryInk)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Color.chip, in: Capsule())
                .overlay(Capsule().stroke(Color.border.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.softPress)
    }
}
