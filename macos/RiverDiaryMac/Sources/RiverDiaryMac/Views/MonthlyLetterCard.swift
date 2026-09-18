import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MonthlyLetterCard: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @Binding var date: Date
    @State private var editing: MonthlyLetter?
    @State private var message: String?
    @State private var favoritesOnly = false

    private var month: String { MonthlyLetter.monthKey(for: date) }
    private var saved: MonthlyLetter? { store.monthlyLetters[month] }
    private var letters: [MonthlyLetter] {
        store.monthlyLetters.values
            .filter { !favoritesOnly || $0.isFavorite }
            .sorted { $0.month > $1.month }
    }

    var body: some View {
        let letter = saved ?? MonthlyLetter.make(
            for: date, entries: store.entries, captures: store.quickCaptures,
            sessions: activity.allSessionsIncludingActive()
        )
        SoftCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("月度河流信", systemImage: "envelope.open").font(.headline)
                    Spacer()
                    Text(saved == nil ? "本机草稿 · 尚未保存" : "已保存 · \(month)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let letter {
                    Text(letter.title).font(.editorial(20)).foregroundStyle(Color.ink)
                    Text(letter.body).font(.ui(13)).lineSpacing(7).textSelection(.enabled)
                    DisclosureGroup("这封信的依据") {
                        Text(letter.evidence).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }
                    HStack(spacing: 8) {
                        Button(saved == nil ? "编辑并保存" : "编辑") { editing = letter }
                            .smallAction(dark: true)
                        if saved == nil {
                            Button("保留这封信") { save(letter) }.smallAction()
                        }
                        Button(letter.isFavorite ? "取消收藏" : "收藏") {
                            var updated = letter
                            updated.isFavorite.toggle()
                            updated.updatedAt = Date()
                            save(updated)
                        }.smallAction()
                        Spacer()
                        Button("复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(letter.markdown, forType: .string)
                            message = "已复制这封信。"
                        }.smallAction()
                        Button("导出 Markdown") { export(letter) }.smallAction()
                    }
                    .buttonStyle(.plain)
                    if saved != nil {
                        Text("保存后保留你的版本，不会随新数据自动改写。")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Text("这个月暂时没有可用的记录。留下日记、快记或足迹后，这里就会出现一封本机草稿。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !store.monthlyLetters.isEmpty {
                    Divider()
                    HStack {
                        Text("已保存的信").font(.subheadline.weight(.semibold))
                        Spacer()
                        Toggle("只看收藏", isOn: $favoritesOnly).toggleStyle(.checkbox).font(.caption)
                    }
                    if letters.isEmpty {
                        Text("还没有收藏的信。").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(letters) { item in
                        Button {
                            if let day = DiaryEntry.dateFormatter.date(from: item.month + "-01") { date = day }
                        } label: {
                            HStack {
                                Image(systemName: item.isFavorite ? "star.fill" : "envelope")
                                Text(item.title).lineLimit(1)
                                Spacer()
                                Text(item.updatedAt.formatted(date: .abbreviated, time: .omitted))
                                    .foregroundStyle(.secondary)
                            }.font(.caption).padding(10)
                                .background(Color.chip, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .onChange(of: month) { message = nil }
        .sheet(item: $editing) { letter in
            MonthlyLetterEditor(letter: letter) { try store.saveMonthlyLetter($0) }
        }
    }

    private func save(_ letter: MonthlyLetter) {
        do {
            try store.saveMonthlyLetter(letter)
            message = "已保存，可在已保存的信中重新打开。"
        } catch { message = "保存未完成：\(error.localizedDescription)" }
    }

    private func export(_ letter: MonthlyLetter) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "河流信-\(letter.month).md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.message = "导出包含正文和依据的可读文件，请选择自己的保存位置。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try letter.markdown.write(to: url, atomically: true, encoding: .utf8)
            message = "已导出到 \(url.lastPathComponent)。"
        } catch { message = "导出未完成：\(error.localizedDescription)" }
    }
}

private struct MonthlyLetterEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var letter: MonthlyLetter
    let onSave: (MonthlyLetter) throws -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("给 \(letter.month) 留一封信").font(.title2)
            TextField("标题", text: $letter.title).textFieldStyle(.roundedBorder)
            TextEditor(text: $letter.body).font(.body).frame(minHeight: 300)
                .accessibilityLabel("河流信正文")
            Toggle("收藏这封信", isOn: $letter.isFavorite)
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    var updated = letter
                    updated.title = updated.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.body = updated.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.updatedAt = Date()
                    do { try onSave(updated); dismiss() }
                    catch { self.error = "保存未完成：\(error.localizedDescription)" }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(letter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || letter.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 620).interactiveDismissDisabled()
    }
}
