import SwiftUI

struct QuickCaptureView: View {
    @ObservedObject var store: DiaryStore
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                BrandMark(size: 22)
                Text("River Diary 快记")
                    .font(.headline)
                Spacer()
                Circle().fill(store.autoDraftPaused ? Color.secondary : Color(hex: "#2C8158"))
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
                    .font(.ui(13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        LinearGradient.river(),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .shadow(color: Color.riverAmethyst.opacity(0.3), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.softPress)

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
