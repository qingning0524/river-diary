import SwiftUI

enum MemorySection: String, CaseIterable, Identifiable {
    case search
    case insight
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "回忆搜索"
        case .insight: "状态"
        case .notes: "随笔"
        }
    }

    var caption: String {
        switch self {
        case .search: "用一句话找到某一天或某段感受"
        case .insight: "本机规则读取重复出现的情绪线索"
        case .notes: "保留随手写下的完整原文"
        }
    }
}

struct MemoryView: View {
    @ObservedObject var ai: AIAssistantStore
    let entries: [DiaryEntry]
    var quickCaptures: [QuickCapture] = []
    @Binding var section: MemorySection
    let openDate: (Date) -> Void

    @State private var query = ""
    @State private var submittedQuery = ""

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("记忆")
                            .font(.system(size: 32, weight: .semibold, design: .serif))
                        Text(section.caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("分区", selection: $section.animation(.easeOut(duration: 0.2))) {
                        ForEach(MemorySection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 340)
                }

                if section == .search {
                    searchSection
                } else if section == .insight {
                    InsightView(entries: entries, ai: ai)
                        .background(.clear)
                } else {
                    NotesView(entries: entries, quickCaptures: quickCaptures, ai: ai) { date in openDate(date) }
                        .background(.clear)
                }
            }
            .frame(maxWidth: 1280, alignment: .leading)
            .padding(.top, 10)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("问一句，例如：哪几天很累？本月提到工作了吗？低于40有哪几天？", text: $query, axis: .vertical)
                    .textFieldStyle(.plain)
                    .onSubmit { submittedQuery = query }

                Button("问回忆") { submittedQuery = query }
                    .buttonStyle(.plain)
                    .primaryCTA()
            }
            .padding(16)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.border, lineWidth: 1))
            .frame(maxWidth: 1280)

            HStack(spacing: 7) {
                suggestion("哪几天很累？")
                suggestion("本月提到工作了吗？")
                suggestion("低于40有哪几天？")
                suggestion("上周的平静记录")
                Spacer()
            }
            .frame(maxWidth: 1280)

            let answer = MemorySearchEngine.search(submittedQuery, entries: entries, quickCaptures: quickCaptures)

            SoftCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("本机规则摘要", systemImage: "text.magnifyingglass")
                        .font(.headline)

                    Text(answer.summary)
                        .font(.system(size: 16, weight: .medium))
                        .lineSpacing(7)

                    if !answer.usedFilters.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(answer.usedFilters, id: \.self) { item in
                                StatusBadge(item)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 1280)

            SoftCard {
                AITaskCard(
                    ai: ai,
                    task: .memorySearch,
                    buttonTitle: "让 AI 回答",
                    emptyMessage: "AI 会结合本机筛选结果和近 40 天日记，给出带日期依据的回答。"
                ) {
                    let question = submittedQuery.isEmpty ? query : submittedQuery
                    Task { await ai.searchMemory(query: question, entries: entries, quickCaptures: quickCaptures) }
                }
            }
            .frame(maxWidth: 1280)

            if !answer.entries.isEmpty {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(answer.entries.reversed()) { entry in
                        Button {
                            if let date = entry.entryDate { openDate(date) }
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(entry.shortDate)
                                        .font(.headline)
                                    Spacer()
                                    Text("\(entry.overall)")
                                        .font(.system(size: 20, weight: .bold))
                                }
                                Text(entry.displayOverview)
                                    .font(.caption)
                                    .lineSpacing(5)
                                    .lineLimit(4)
                                    .foregroundStyle(.secondary)
                                if let signal = MoodAnalyzer.reading(for: entry.displayOverview).signals.first {
                                    Text("#\(signal.word)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .background(Color.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 1280)
            }

            if !answer.notes.isEmpty {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(answer.notes) { note in
                        Button {
                            if let date = DiaryEntry.dateFormatter.date(from: note.date) { openDate(date) }
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(note.date)
                                        .font(.caption.smallCaps())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if let signal = note.signal {
                                        Text("#\(signal)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(note.text)
                                    .font(.caption)
                                    .lineSpacing(5)
                                    .lineLimit(5)
                                    .frame(minHeight: 64, alignment: .topLeading)
                                ForEach(note.tags.prefix(2), id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(17)
                            .background(Color.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 1280)
            }
        }
        .frame(maxWidth: 1280, alignment: .leading)
    }

    private func suggestion(_ text: String) -> some View {
        Button(text) {
            query = text
            submittedQuery = text
        }
        .font(.caption)
        .buttonStyle(.plain)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color.chip, in: Capsule())
    }
}
