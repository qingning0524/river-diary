import SwiftUI

struct QuickCaptureView: View {
    @Environment(\.riverDensity) private var density
    @ObservedObject var store: DiaryStore
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.md)) {
            HStack(spacing: density.spacing(AppSpacing.sm)) {
                BrandMark(size: 22)
                Text("River Diary 快记")
                    .font(AppTypography.rowTitle())
                Spacer()
                Circle().fill(store.autoDraftPaused ? Color.secondaryInk : AppTheme.ok)
                    .frame(width: 7, height: 7)
                Text(store.autoDraftPaused ? "已暂停" : "记录中")
                    .font(AppTypography.micro())
                    .foregroundStyle(Color.secondaryInk)
            }

            Text("先保留一句话或链接，稍后可以放进当天日记。")
                .font(AppTypography.metadata())
                .foregroundStyle(Color.secondaryInk)

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
