import SwiftUI

struct TodayDateNavigator: View {
    @EnvironmentObject private var store: DiaryStore
    let current: DiaryEntry

    var body: some View {
        let index = store.entries.firstIndex { $0.id == current.id } ?? 0

        return HStack(spacing: 10) {
            circularIconButton(
                "chevron.left",
                accessibilityLabel: "查看前一天",
                isDisabled: index + 1 >= store.entries.count
            ) {
                guard index + 1 < store.entries.count else { return }
                store.select(store.entries[index + 1])
            }

            VStack(spacing: 2) {
                Text(current.entryDate, style: .date)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(Calendar.current.isDateInToday(current.entryDate) ? "今天" : current.shortDate)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(.thinMaterial, in: .capsule)

            circularIconButton(
                "chevron.right",
                accessibilityLabel: "查看后一天",
                isDisabled: index == 0
            ) {
                guard index > 0 else { return }
                store.select(store.entries[index - 1])
            }
        }
    }

    private func circularIconButton(
        _ systemImage: String,
        accessibilityLabel: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: 38, height: 38)
                .background(.quaternary.opacity(0.75), in: .circle)
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
    }

}
