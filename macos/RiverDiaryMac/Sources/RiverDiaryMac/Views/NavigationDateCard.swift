import SwiftUI

struct NavigationDateCard: View {
    @Binding var selection: Date
    @State private var showsCalendar = false

    private var isToday: Bool { Calendar.current.isDateInToday(selection) }
    private var isTomorrow: Bool {
        Calendar.current.isDate(
            selection,
            inSameDayAs: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        )
    }
    private var latestSelectableDate: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    }
    private var dateText: String {
        let day = selection.formatted(.dateTime.month().day())
        return isToday ? "今天 · \(day)" : day
    }

    var body: some View {
        HStack(spacing: 3) {
            arrowButton(direction: -1)

            Button {
                showsCalendar.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.ctaText)

                    Text(dateText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(selection.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption2)
                        .foregroundStyle(isToday ? Color.ctaText : .secondary)

                    if isToday {
                        Circle()
                            .fill(Color(hex: "#2C8158"))
                            .frame(width: 5, height: 5)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
                DatePicker(
                    "选择日期",
                    selection: $selection,
                    in: ...latestSelectableDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(12)
            }

            arrowButton(direction: 1)

            if !isToday {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = Date() }
                } label: {
                    Text("回今天")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.secondaryInk)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 36)
                        .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("回到今天")
            }
        }
        .padding(3)
        .background(Color.chip.opacity(0.55), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.border, lineWidth: 1)
        )
    }

    private func arrowButton(direction: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                selection = Calendar.current.date(byAdding: .day, value: direction, to: selection) ?? selection
            }
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondaryInk)
                .frame(width: 26, height: 36)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(direction > 0 && isTomorrow)
        .keyboardShortcut(direction < 0 ? .leftArrow : .rightArrow, modifiers: .command)
        .help(direction < 0 ? "前一天" : "后一天")
    }
}
