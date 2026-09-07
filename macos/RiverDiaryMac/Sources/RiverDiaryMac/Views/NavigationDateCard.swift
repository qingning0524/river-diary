import SwiftUI

struct NavigationDateCard: View {
    @Binding var selection: Date
    @State private var showsCalendar = false

    private var isToday: Bool { Calendar.current.isDateInToday(selection) }
    private var isTomorrow: Bool { Calendar.current.isDate(selection, inSameDayAs: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()) }
    private var latestSelectableDate: Date { Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date() }
    private var dateText: String {
        let weekday = selection.formatted(.dateTime.weekday(.abbreviated))
        let day = selection.formatted(.dateTime.month().day())
        return isToday ? "今天 · \(day)" : "\(day) \(weekday)"
    }

    var body: some View {
        HStack(spacing: 5) {
            arrowButton(direction: -1)

            Button {
                showsCalendar.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.ctaText)

                    Text(dateText)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if !isToday {
                        Text("统一")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
                DatePicker(
                    "统一选择日期",
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
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.secondaryInk)
                        .frame(width: 26, height: 32)
                        .background(Color.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("回今天")
            }
        }
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
                .frame(width: 24, height: 32)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(direction > 0 && isTomorrow)
        .keyboardShortcut(direction < 0 ? .leftArrow : .rightArrow, modifiers: .command)
        .help(direction < 0 ? "前一天" : "后一天")
    }
}
