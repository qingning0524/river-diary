import SwiftUI

struct TimelineAnnotationEditor: View {
    let item: ActivityTimelineItem
    let save: (TimelineAnnotation) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var note: String
    @State private var favorite: Bool
    @State private var errorMessage: String?

    init(item: ActivityTimelineItem, save: @escaping (TimelineAnnotation) throws -> Void) {
        self.item = item
        self.save = save
        _title = State(initialValue: item.annotation?.title ?? "")
        _note = State(initialValue: item.annotation?.note ?? "")
        _favorite = State(initialValue: item.isFavorite)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("把这段时间，写成自己的话")
                        .font(.system(size: 23, weight: .medium, design: .serif))
                    Text("\(item.start.formatted(date: .abbreviated, time: .shortened)) – \(item.end.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "pencil.line").font(.system(size: 22)).foregroundStyle(Color.riverAmethyst)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("给片段起个名字").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("使用自动标题") { title = "" }
                        .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Color.riverAmethyst)
                        .disabled(title.isEmpty)
                }
                TextField(item.summary, text: $title, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(1...3)
                    .padding(12).background(Color.chip.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("当时的感受与想法").font(.system(size: 12, weight: .medium))
                TextEditor(text: $note)
                    .font(.system(size: 14)).scrollContentBackground(.hidden)
                    .padding(8).frame(height: 150)
                    .background(Color.chip.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("片段感受与想法")
            }
            Toggle(isOn: $favorite) {
                Label("收藏这段时间", systemImage: favorite ? "star.fill" : "star")
                    .font(.system(size: 12))
            }
            Text("你的文字保存在这台 Mac 的加密日记中，原始应用片段仍会保留。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存整理") {
                    do {
                        try save(TimelineAnnotation(title: title, note: note, isFavorite: favorite))
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).tint(Color.riverAmethyst)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 510).background(Color.editor)
    }
}
