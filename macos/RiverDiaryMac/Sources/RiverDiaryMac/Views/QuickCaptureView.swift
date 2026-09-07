import SwiftUI

struct QuickCaptureView: View {
    @ObservedObject var store: DiaryStore
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("River Diary 快记")
                    .font(.headline)
                Spacer()
                Circle().fill(store.autoDraftPaused ? Color.secondary : Color(hex: "#7CB342"))
                    .frame(width: 7, height: 7)
            }

            Text("先保留一句话或链接，稍后会并进当天草稿。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("今天想到什么？", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .onSubmit(save)

            Button {
                save()
            } label: {
                Label("保留到今天", systemImage: "tray.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if case .saved(let date) = store.saveState {
                Text("已保存 \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func save() {
        store.addQuickCapture(text)
        text = ""
    }
}
