import SwiftUI

struct MemoryArchiveView: View {
    let entries: [DiaryEntry]
    let captures: [String: [QuickCapture]]
    let openDate: (Date) -> Void
    @State private var query = ""
    @State private var month = ""
    @State private var onlyWriting = false
    @State private var selectedID: String?

    private var days: [MemoryArchiveDay] { MemoryArchive.days(entries: entries, captures: captures) }
    private var filtered: [MemoryArchiveDay] {
        days.filter { $0.matches(query) && (month.isEmpty || $0.id.hasPrefix(month)) && (!onlyWriting || $0.hasWriting) }
    }
    private var selected: MemoryArchiveDay? { filtered.first { $0.id == selectedID } ?? filtered.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索原文、快记、标签或日期", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
                }.font(.system(size: 13)).padding(10).background(Color.chip.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                Picker("月份", selection: $month) {
                    Text("所有月份").tag("")
                    ForEach(Array(Set(days.map { String($0.id.prefix(7)) })).sorted(by: >), id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 135)
                Toggle("只看日记", isOn: $onlyWriting).font(.system(size: 11))
            }.padding(18)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(filtered.count) 天记忆").font(.system(size: 10)).foregroundStyle(.tertiary).padding(16)
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(filtered) { day in
                                Button { selectedID = day.id } label: { row(day) }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 8).padding(.bottom, 14)
                    }
                }.frame(width: 290)
                Divider()
                if let selected {
                    reader(selected).id(selected.id)
                } else {
                    ContentUnavailableView("没有找到这段回忆", systemImage: "book.closed", description: Text("换个关键词，或试试其他月份。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color.strongSurface, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.separator, lineWidth: 1))
    }

    private func row(_ day: MemoryArchiveDay) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(day.entry.shortDate).font(.system(size: 13, weight: .medium))
                Text(String(day.id.prefix(4))).font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                if let mood = day.mood, mood.isFinite { Text("\(Int(mood))").font(.system(size: 12, design: .rounded)).foregroundStyle(Color.riverAmethyst) }
            }
            Text(day.preview).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).lineSpacing(3)
            HStack(spacing: 7) {
                if day.hasWriting { Text("日记") }
                if !day.captures.isEmpty { Text("\(day.captures.count) 条快记") }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 8))
            }.font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected?.id == day.id ? Color.riverAmethyst.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    private func reader(_ day: MemoryArchiveDay) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("FROM YOUR MEMORY").font(.system(size: 9, design: .monospaced)).tracking(2).foregroundStyle(Color.riverAmethyst)
                    Spacer()
                    Button("打开这篇日记") { if let date = day.entry.entryDate { openDate(date) } }
                        .font(.system(size: 11)).buttonStyle(.bordered)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(day.entry.entryDate?.formatted(date: .complete, time: .omitted) ?? day.id)
                        .font(.editorial(27))
                    if let category = day.entry.category { Text(category).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                if day.hasWriting {
                    Text(day.entry.displayOverview).font(.system(size: 16)).lineSpacing(10).textSelection(.enabled)
                }
                ForEach(Array((day.entry.thoughts ?? []).enumerated()), id: \.offset) { _, thought in
                    Text(thought).font(.system(size: 14)).lineSpacing(8).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ForEach(Array((day.entry.memos ?? []).enumerated()), id: \.offset) { _, memo in
                    Text(memo).font(.system(size: 14)).lineSpacing(8).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !day.captures.isEmpty {
                    Divider()
                    Label("当天留下的快记", systemImage: "quote.bubble").font(.system(size: 12, weight: .medium))
                    ForEach(day.captures) { capture in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(capture.text).font(.system(size: 14)).lineSpacing(7).textSelection(.enabled)
                            Text("写于 " + capture.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.riverAmethyst.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                if let tags = day.entry.tags, !tags.isEmpty {
                    Text(tags.map { "#" + $0 }.joined(separator: "  ")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
