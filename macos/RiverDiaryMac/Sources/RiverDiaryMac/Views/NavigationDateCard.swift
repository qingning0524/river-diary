import SwiftUI

struct NavigationDateCard: View {
    @Binding var selection: Date
    @State private var showsCalendar = false
    private var isToday: Bool { Calendar.current.isDateInToday(selection) }
    private var latest: Date { Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date() }

    var body: some View {
        HStack(spacing: 5) {
            arrow(-1)
            Button { showsCalendar.toggle() } label: {
                HStack(spacing: 7) {
                    Text(isToday ? "今天" : selection.formatted(.dateTime.month().day()))
                        .font(.system(size: 12, weight: .medium))
                    Text(selection.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 9).frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsCalendar) {
                DatePicker("选择日记日期", selection: $selection, in: ...latest, displayedComponents: .date)
                    .datePickerStyle(.graphical).padding(14)
            }
            arrow(1)
            if !isToday {
                Button("今天") { selection = Date() }.font(.system(size: 10)).buttonStyle(.plain)
                    .foregroundStyle(Color.riverAmethyst).padding(.leading, 5)
            }
        }.onChange(of: selection) { showsCalendar = false }
    }
    private func arrow(_ direction: Int) -> some View {
        Button { selection = Calendar.current.date(byAdding: .day, value: direction, to: selection) ?? selection } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 23, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(direction > 0 && Calendar.current.startOfDay(for: selection) >= Calendar.current.startOfDay(for: latest))
        .keyboardShortcut(direction < 0 ? .leftArrow : .rightArrow, modifiers: .command)
        .help(direction < 0 ? "前一天" : "后一天")
    }
}
