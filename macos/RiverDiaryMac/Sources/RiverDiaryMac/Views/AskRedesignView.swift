import SwiftUI

struct AskRedesignView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    var onShowEvidence: (String, [DiaryEntry], [QuickCapture]) -> Void

    @State private var query = "What have I been working on this week?"
    @State private var answer: AskedAnswer?
    @State private var isSearching = false

    private struct AskedAnswer: Identifiable {
        var id: String { query }
        let query: String
        let memory: MemoryAnswer
        let captures: [QuickCapture]
    }

    private var allCaptures: [QuickCapture] {
        store.quickCaptures.values.flatMap(\.self)
    }

    var body: some View {
        VStack(alignment: .center, spacing: 24) {
            Spacer(minLength: 40)
            VStack(alignment: .center, spacing: 6) {
                Text("ASK YOUR PAST")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(Color.riverAmethyst)
                Text("Ask River")
                    .font(.editorial(32, weight: .semibold))
                    .foregroundStyle(Color.ink)
            }
            Text("Answers point back to evidence.")
                .font(.ui(12))
                .foregroundStyle(Color.secondaryInk)

            HStack(spacing: 8) {
                TextField("Ask…", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(run)
                Button("Ask", action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSearching)
            }
            .font(.system(size: 14))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: 560)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

            if let answer {
                answerView(answer)
            } else {
                hint
            }
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 32)
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

    private func run() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        let memory = MemorySearchEngine.search(trimmed, entries: store.entries, quickCaptures: allCaptures)
        answer = AskedAnswer(query: trimmed, memory: memory, captures: allCaptures)
        isSearching = false
    }

    @ViewBuilder
    private func answerView(_ answer: AskedAnswer) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            let memory = answer.memory
            VStack(alignment: .leading, spacing: 8) {
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
                Text(memory.summary)
                    .font(.editorial(17, weight: .regular))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: 640, alignment: .leading)
            }

            let count = memory.entries.count + (answer.memory.notes.isEmpty ? 0 : memory.notes.count)
            Button {
                onShowEvidence(
                    answer.query,
                    memory.entries,
                    answer.captures.filter { capture in
                        memory.entries.contains { $0.date == DiaryEntry.dateFormatter.string(from: capture.createdAt) }
                    }
                )
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                    Text("Based on \(count) entries · view evidence")
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
        .padding(.top, 12)
    }
}
