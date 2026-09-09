import SwiftUI

private struct CompactDateSelector: View {
    @Binding var selection: Date
    @State private var visibleMonth: Date
    @Environment(\.dismiss) private var dismiss

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 5), count: 7)
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    init(selection: Binding<Date>) {
        _selection = selection
        _visibleMonth = State(initialValue: calendar.startOfMonth(selection.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Button {
                    moveMonth(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 27, height: 27)
                        .background(Color.chip, in: Circle())
                }
                .buttonStyle(.plain)

                Spacer()
                Text(monthTitle)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()

                Button {
                    moveMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 27, height: 27)
                        .background(Color.chip, in: Circle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 5) {
                ForEach(weekdays, id: \.self) { weekday in
                    Text(weekday)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 34)
                }
            }

            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(0..<leadingBlankCount, id: \.self) { _ in
                    Color.clear.frame(width: 34, height: 32)
                }

                ForEach(daysInMonth, id: \.self) { day in
                    dayButton(day)
                }
            }

            Divider()

            HStack {
                Button("回到今天") {
                    selection = Date()
                    dismiss()
                }
                .font(.caption)
                .buttonStyle(.softPress)
                .smallAction()

                Spacer()
                Text("最多查看未来 1 天")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: 290)
        .background(Color.surface)
    }

    private var monthTitle: String {
        visibleMonth.formatted(.dateTime.year().month(.wide))
    }

    private var daysInMonth: [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: visibleMonth) else { return [] }
        var dates: [Date] = []
        var cursor = interval.start
        while cursor < interval.end {
            dates.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? interval.end
        }
        return dates
    }

    private var leadingBlankCount: Int {
        let firstWeekday = calendar.component(.weekday, from: visibleMonth)
        let isoWeekday = firstWeekday == 1 ? 7 : firstWeekday - 1
        return isoWeekday - 1
    }

    private func moveMonth(_ direction: Int) {
        visibleMonth = calendar.date(byAdding: .month, value: direction, to: visibleMonth) ?? visibleMonth
    }

    private func dayButton(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selection)
        let isToday = calendar.isDateInToday(day)
        let isFuture = day > Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
        let dayNumber = calendar.component(.day, from: day)

        return Button {
            selection = day
            dismiss()
        } label: {
            Text("\(dayNumber)")
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isFuture ? Color.secondaryInk.opacity(0.35) : isSelected ? .white : isToday ? Color.riverAmethyst : Color.secondaryInk)
                .frame(width: 34, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            isSelected
                                ? AnyShapeStyle(LinearGradient.river())
                                : AnyShapeStyle(isToday ? Color.riverAmethyst.opacity(0.14) : Color.clear)
                        )
                        .overlay {
                            if isToday && !isSelected {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.riverAmethyst.opacity(0.45), lineWidth: 1)
                            }
                        }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.softPress)
        .disabled(isFuture)
        .help(day.formatted(date: .complete, time: .omitted))
    }
}

extension Calendar {
    func startOfMonth(_ date: Date) -> Date {
        let components = dateComponents([.year, .month], from: date)
        return self.date(from: components) ?? date
    }
}
