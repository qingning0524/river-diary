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
                Circle().fill(store.autoDraftPaused ? Color.secondary : AppTheme.ok)
                    .frame(width: 7, height: 7)
            }

            Text("先保留一句话或链接，稍后可以放进当天日记。")
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
            .primaryCTA()

            if case .failed(let message) = store.saveState {
                Text(message)
                    .font(AppTypography.metadata())
                    .foregroundStyle(AppTheme.error)
            }
            if case .saved(let date) = store.saveState {
                Text("已保存 \(date.formatted(date: .omitted, time: .shortened))")
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.secondaryInk)
            }
        }
        .padding(AppSpacing.panelPadding)
        .frame(width: 280)
    }

    private func save() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if store.addQuickCapture(text) {
            text = ""
        }
    }
}
