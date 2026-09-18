import SwiftUI

struct WorkspaceCaptureSheet: View {
    @ObservedObject var store: DiaryStore
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("一句话，也是一篇日记的开始。")
                .font(.editorial(24))
            Text("留给 \(date.formatted(date: .abbreviated, time: .omitted))")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 16)).scrollContentBackground(.hidden)
                .padding(12).frame(height: 130).background(Color.chip, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("快记内容")
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("留下这句") {
                    store.addQuickCapture(text, for: date)
                    if case .failed(let message) = store.saveState { error = message }
                    else { dismiss() }
                }.buttonStyle(.borderedProminent).tint(Color.riverAmethyst)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 480).background(Color.workspace)
    }
}

enum WorkspaceCommand {
    case destination(AppDestination), today, capture, date(Date)
}

struct WorkspaceCommandPalette: View {
    let perform: (WorkspaceCommand) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("前往页面，或输入日期 2026-09-16", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .onSubmit {
                        if let date = Self.parsedDate(query) { run(.date(date)) }
                        else if let page = AppDestination.allCases.first(where: { $0.title.localizedStandardContains(query) }) { run(.destination(page)) }
                    }
            }.padding(10)
            Divider()
            ForEach(AppDestination.allCases.filter { query.isEmpty || $0.title.localizedStandardContains(query) }) { page in
                Button { run(.destination(page)) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: page.icon).frame(width: 22)
                        Text(page.title)
                        Spacer()
                        Text("⌘\(page.shortcutNumber)").foregroundStyle(.tertiary)
                    }.font(.system(size: 14)).padding(10).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if query.isEmpty {
                Button("回到今天") { run(.today) }.buttonStyle(.plain).padding(10)
            }
            if let date = Self.parsedDate(query) {
                Button("打开 \(date.formatted(date: .complete, time: .omitted)) 的日记") { run(.date(date)) }
                    .buttonStyle(.plain).padding(10)
            }
            HStack {
                Text("⌘1–⌘5 切换页面 · ⇧⌘N 记录一句")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.plain).font(.system(size: 11))
            }.padding(10)
        }.padding(16).frame(width: 490).background(Color.workspace)
    }
    private func run(_ command: WorkspaceCommand) { dismiss(); perform(command) }
    static func parsedDate(_ query: String) -> Date? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count == 10, let date = DiaryEntry.dateFormatter.date(from: text), DiaryEntry.dateFormatter.string(from: date) == text else { return nil }
        return date
    }
}
