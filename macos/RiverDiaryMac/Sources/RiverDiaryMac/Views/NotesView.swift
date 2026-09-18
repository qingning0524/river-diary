import SwiftUI

struct NotesView: View {
    struct Note: Identifiable, Hashable {
        let id: String
        let date: String
        let text: String
        let kind: String
        let tags: [String]

        var kindLabel: String {
            switch kind {
            case "工作": "工作"
            case "身心": "身心"
            case "休息": "休息"
            case "快记": "快记"
            default: "随想"
            }
        }

        var title: String {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.count > 22 ? String(clean.prefix(22)) + "…" : clean
        }
    }

    let entries: [DiaryEntry]
    var quickCaptures: [QuickCapture] = []
    var assignedCaptures: [String: [QuickCapture]] = [:]
    @ObservedObject var ai: AIAssistantStore
    var showsHeader: Bool = true
    var openDate: ((Date) -> Void)? = nil

    @State private var filter = "全部"
    @State private var searchText = ""

    private var notes: [Note] {
        let diaryNotes = entries.flatMap { entry -> [Note] in
            var texts = [entry.displayOverview]
            texts.append(contentsOf: entry.thoughts ?? [])
            texts.append(contentsOf: entry.memos ?? [])

            return texts
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .enumerated()
                .map { index, text in
                    Note(
                        id: "\(entry.id)-\(index)",
                        date: entry.date,
                        text: text,
                        kind: storeCategory(entry),
                        tags: entry.tags ?? []
                    )
                }
        }

        let assignedDays = assignedCaptures.reduce(into: [UUID: String]()) { result, pair in
            for capture in pair.value { result[capture.id] = pair.key }
        }
        let captureNotes = quickCaptures.map { capture in
            Note(
                id: capture.id.uuidString,
                date: assignedDays[capture.id] ?? DiaryEntry.dateFormatter.string(from: capture.createdAt),
                text: capture.text,
                kind: "快记",
                tags: [capture.source]
            )
        }

        return (diaryNotes + captureNotes).sorted { $0.date > $1.date }
    }

    private func storeCategory(_ entry: DiaryEntry) -> String {
        switch entry.category ?? "随想" {
        case "工作", "身心", "休息": entry.category!
        default: "随想"
        }
    }

    private var filtered: [Note] {
        notes.filter { note in
            let matchesFilter = filter == "全部" || note.kind == filter
            let matchesSearch = searchText.isEmpty || note.text.localizedCaseInsensitiveContains(searchText) || note.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            return matchesFilter && matchesSearch
        }
    }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    if showsHeader {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 9) {
                                Text("随笔与灵感")
                                    .font(.editorial(34))
                                    .foregroundStyle(Color.ink)

                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(LinearGradient.river())
                                    .frame(width: 28, height: 3)
                                    .offset(y: 6)
                            }

                            Text("保留随手写下的完整原文")
                                .font(.ui(12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)
                        TextField("搜索文字或标签", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.ui(12.5))
                            .frame(width: 190)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(Color.strongSurface, in: Capsule())
                    .overlay(Capsule().stroke(Color.border, lineWidth: 1))
                }
                .frame(maxWidth: AppLayout.contentMaxWidth)

                SoftCard {
                    AITaskCard(
                        ai: ai,
                        task: .noteThemes,
                        buttonTitle: "AI 归纳主题",
                        emptyMessage: "AI 会把零散随笔和快记整理成主题，方便以后回看。"
                    ) {
                        Task { await ai.organizeNotes(entries: entries, quickCaptures: quickCaptures) }
                    }
                }
                .frame(maxWidth: AppLayout.contentMaxWidth)

                HStack(spacing: 7) {
                    filterButton("全部", "全部")
                    filterButton("随想", "随想")
                    filterButton("工作", "工作")
                    filterButton("身心", "身心")
                    filterButton("休息", "休息")
                    filterButton("快记", "快记")
                    Spacer()
                    Text("\(filtered.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: AppLayout.contentMaxWidth)

                Group {
                    if filtered.isEmpty {
                        SoftCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("没有匹配的记录").font(.headline)
                            Text("试试另一个关键词，或清除筛选条件。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        }
                    } else {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(filtered) { note in
                                noteCard(note)
                            }
                        }
                    }
                }
                .frame(maxWidth: AppLayout.contentMaxWidth)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }

    private func filterButton(_ title: String, _ value: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { filter = value }
        } label: {
            Text(title)
                .font(.ui(12, weight: filter == value ? .semibold : .medium))
                .foregroundStyle(filter == value ? .white : Color.secondaryInk)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(
                    filter == value ? AnyShapeStyle(LinearGradient.river()) : AnyShapeStyle(Color.chip),
                    in: Capsule()
                )
                .shadow(color: filter == value ? Color.riverAmethyst.opacity(0.28) : .clear, radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.softPress)
    }

    private func noteCard(_ note: Note) -> some View {
        Button {
            if let date = DiaryEntry.dateFormatter.date(from: note.date) {
                openDate?(date)
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(note.shortDateLabel) · \(note.kindLabel)")
                        .font(.caption2.smallCaps())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }

                Text(note.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(Color.ink)

                Text(note.text)
                    .font(.caption)
                    .lineSpacing(5)
                    .lineLimit(4)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 58, alignment: .topLeading)

                if !note.tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(note.tags.prefix(3), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.riverAmethyst)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.riverAmethyst.opacity(0.09), in: Capsule())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.09), radius: 2, x: 0, y: 1)
            .shadow(color: .black.opacity(0.05), radius: 16, x: 0, y: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.softPress)
    }
}

extension NotesView.Note {
    var shortDateLabel: String {
        let parts = date.split(separator: "-")
        guard parts.count == 3 else { return date }
        return "\(Int(parts[1]) ?? 1).\(Int(parts[2]) ?? 1)"
    }
}
