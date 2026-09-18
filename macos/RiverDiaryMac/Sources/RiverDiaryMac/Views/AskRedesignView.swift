import SwiftUI

struct AskRedesignView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @Binding var query: String
    var savedQueries: [SavedQuery]
    var onShowEvidence: (String, [DiaryEntry], [QuickCapture]) -> Void

    @State private var answer: AskedAnswer?
    @State private var history: [AskedAnswer] = []
    @State private var isSearching = false

    private struct AskedAnswer: Identifiable {
        var id: String { "\(query)|\(Date().timeIntervalSince1970)" }
        let query: String
        let memory: MemoryAnswer
        let captures: [QuickCapture]
    }

    private var allCaptures: [QuickCapture] {
        store.quickCaptures.values.flatMap(\.self)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                inputBar
                if let answer {
                    answerView(answer)
                    recentQuestions
                } else {
                    hint
                }
                if !savedQueries.isEmpty {
                    savedQueryRow
                }
            }
            .frame(maxWidth: 760, minHeight: 520, alignment: .topLeading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack {
            PageTitle(title: "Ask River", subtitle: "答案会回到证据。")
            Spacer()
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Ask…", text: $query)
                .textFieldStyle(.plain)
                .onSubmit(run)
            if !query.isEmpty && answer == nil {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除")
            }
            Button("Ask", action: run)
                .buttonStyle(.borderedProminent)
                .disabled(isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 680)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var hint: some View {
        VStack(spacing: 10) {
            suggestion("今天做了什么？")
            suggestion("上周主要做了什么？")
            suggestion("本月提到工作了吗？")
        }
        .padding(.top, 8)
    }

    private func suggestion(_ text: String) -> some View {
        Button {
            query = text
            run()
        } label: {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var savedQueryRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("SAVED QUERIES")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.3)
                    .foregroundStyle(Color.secondaryInk.opacity(0.9))
                Text("\(savedQueries.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 560, alignment: .leading)

            ChipFlow(spacing: 8) {
                ForEach(Array(savedQueries.prefix(10)), id: \.id) { saved in
                    Button {
                        query = saved.query
                        run()
                    } label: {
                        Label(saved.name, systemImage: "bookmark")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondaryInk)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(saved.rangeLabel)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .padding(.top, 4)
    }

    private var recentQuestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECENT")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(Color.secondaryInk.opacity(0.9))
            ChipFlow(spacing: 8) {
                ForEach(history.suffix(5).reversed(), id: \.id) { item in
                    Button {
                        query = item.query
                        run()
                    } label: {
                        Text(item.query)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    // MARK: Run

    private func run() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        let memory = MemorySearchEngine.search(trimmed, entries: store.entries, quickCaptures: allCaptures)
        let result = AskedAnswer(query: trimmed, memory: memory, captures: allCaptures)
        answer = result
        history.append(result)
        if history.count > 12 { history.removeFirst(history.count - 12) }
        isSearching = false
    }

    // MARK: Answer

    @ViewBuilder
    private func answerView(_ answer: AskedAnswer) -> some View {
        let memory = answer.memory
        let entryCount = memory.entries.count
        let noteCount = memory.notes.count
        let captureCount = answer.captures.filter { capture in
            memory.entries.contains { $0.date == DiaryEntry.dateFormatter.string(from: capture.createdAt) }
        }.count
        let hasEvidence = entryCount > 0 || noteCount > 0

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                QuietSectionHeader(title: "Answer")
                Spacer()
                Button {
                    saveQuery(answer.query)
                } label: {
                    Label("保存查询", systemImage: "bookmark")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(savedQueries.contains { $0.query == answer.query })
                Button {
                    answerReset()
                } label: {
                    Label("Ask again", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !memory.usedFilters.isEmpty {
                HStack(spacing: 6) {
                    ForEach(memory.usedFilters, id: \.self) { filter in
                        Text(filter)
                            .font(.system(size: 10))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
            }

            if !hasEvidence {
                EmptyStateView(
                    title: "没有找到相关记忆",
                    message: "没有证据能回答这个问题。换一种说法，或试试点击下面的已保存查询。",
                    actionTitle: "换一个问题",
                    action: { answerReset() }
                )
                .font(.system(size: 12))
            } else {
                Text(memory.summary.isEmpty ? "找到了与这个问题相关的记录。" : memory.summary)
                    .font(.editorial(17, weight: .regular))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: 640, alignment: .leading)

                HStack(spacing: 14) {
                    countStat("\(entryCount)", "天")
                    if noteCount > 0 { countStat("\(noteCount)", "篇笔记") }
                    if captureCount > 0 { countStat("\(captureCount)", "条快记") }
                }

                Button {
                    onShowEvidence(answer.query, memory.entries, answer.captures)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                        Text("Based on \(entryCount + noteCount + captureCount) pieces of evidence · view evidence")
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.bordered)

                if !memory.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(memory.entries.prefix(5)), id: \.id) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(entry.shortDate)
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 60, alignment: .trailing)
                                Text(entry.displayOverview)
                                    .font(.system(size: 12))
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 640, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(.top, 8)
    }

    private func countStat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.ink)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func answerReset() {
        answer = nil
        query = ""
    }

    private func saveQuery(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !savedQueries.contains(where: { $0.query == trimmed }) else { return }
        let name = trimmed.count <= 16 ? trimmed : String(trimmed.prefix(16)) + "…"
        try? store.saveSavedQuery(SavedQuery(name: name, query: trimmed, days: 30))
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
