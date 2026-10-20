import Combine
import SwiftUI

struct DateContext: Equatable {
    var selectedDate: Date = Date()

    var isToday: Bool { Calendar.current.isDateInToday(selectedDate) }
    var canMoveForward: Bool {
        let calendar = Calendar.current
        return calendar.startOfDay(for: selectedDate) < calendar.startOfDay(for: Date())
    }

    mutating func moveDay(_ offset: Int, now: Date = Date()) {
        guard offset != 0 else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let current = calendar.startOfDay(for: selectedDate)
        guard offset < 0 || current < today,
              let target = calendar.date(byAdding: .day, value: offset, to: current) else { return }
        selectedDate = offset > 0 && target > today ? today : target
    }

    mutating func goToday() {
        selectedDate = Date()
    }
}

/// Date context lives outside the shell's value view hierarchy so opening or
/// closing the inspector cannot reset the user's place in the river.
@MainActor
final class DateContextStore: ObservableObject {
    @Published private(set) var selectedDate: Date

    private let defaults: UserDefaults
    private let selectedDateKey = "river.dateContext.selectedDate"

    init(selectedDate: Date = Date(), defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let storedDate = defaults.object(forKey: selectedDateKey) as? Double {
            self.selectedDate = Date(timeIntervalSinceReferenceDate: storedDate)
        } else {
            self.selectedDate = selectedDate
        }
    }

    private var value: DateContext { DateContext(selectedDate: selectedDate) }
    var isToday: Bool { value.isToday }
    var canMoveForward: Bool { value.canMoveForward }

    func moveDay(_ offset: Int) {
        var updated = value
        updated.moveDay(offset)
        guard updated.selectedDate != selectedDate else { return }
        selectedDate = updated.selectedDate
        persist()
    }

    func goToday() {
        selectedDate = Date()
        persist()
    }

    func setSelectedDate(_ date: Date) {
        selectedDate = date
        persist()
    }

    private func persist() {
        defaults.set(selectedDate.timeIntervalSinceReferenceDate, forKey: selectedDateKey)
    }
}

struct SidebarDateNavigator: View {
    @ObservedObject var context: DateContextStore
    @Environment(\.riverDensity) private var density
    @State private var showsCalendar = false

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            // 换日快捷键收敛到菜单里的 ⌘[ / ⌘]（见 AppCommands）。
            // 之前 ⌘←/⌘→ 作为按钮 key equivalent 是全局的，会劫持
            // 文本编辑器里"光标移到行首/行尾"的标准操作。
            chevronButton("chevron.left", action: { context.moveDay(-1) })
                .help("前一天 (⌘[)")
                .accessibilityLabel("前一天")

            Button { showsCalendar.toggle() } label: {
                HStack(spacing: density.spacing(6)) {
                    Text(context.selectedDate.formatted(.dateTime.month().day().weekday(.abbreviated)))
                        .font(AppTypography.rowTitle().weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Image(systemName: "calendar")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.tertiaryInk)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, density.spacing(AppSpacing.xs))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择日期，当前日期 \(context.selectedDate.formatted(.dateTime.year().month().day()))")
            .help("选择日期")
            .popover(isPresented: $showsCalendar, arrowEdge: .trailing) {
                DatePicker(
                    "选择日期",
                    selection: Binding(
                        get: { context.selectedDate },
                        set: { context.setSelectedDate($0) }
                    ),
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .frame(width: 250)
                .padding(AppSpacing.sm)
                .onChange(of: context.selectedDate) { _, _ in showsCalendar = false }
            }

            chevronButton("chevron.right", action: { context.moveDay(1) })
                .disabled(!context.canMoveForward)
                .help("下一天 (⌘])")
                .accessibilityLabel("下一天")

            if !context.isToday {
                FilterChip(title: "今天", isSelected: false, action: { context.goToday() })
                    .help("回到今天")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func chevronButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondaryInk)
                .frame(width: 22, height: 24)
                .background(Color.chip, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .strokeBorder(Color.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
