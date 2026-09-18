import SwiftUI

/// Date navigation lives with the timeline so the diary, notes and evidence move together.
struct TimelineWorkspaceHeader: View {
    @Binding var date: Date
    let recordedDays: Set<String>
    var openDiary: (() -> Void)?
    @State private var showsCalendar = false

    private var week: [Date] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DAY BY DAY")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(2.5).foregroundStyle(Color.riverAmethyst)
                    Text("生活时间线")
                        .font(.system(size: 32, weight: .medium, design: .serif))
                        .foregroundStyle(Color.ink)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 32) }
                        .help("前一天").keyboardShortcut(.leftArrow, modifiers: .command)
                    Button { showsCalendar.toggle() } label: {
                        HStack(spacing: 8) {
                            Text(date.formatted(.dateTime.year().month(.wide)))
                            Image(systemName: "calendar").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 9)
                    }
                    .popover(isPresented: $showsCalendar) {
                        DatePicker("选择日期", selection: $date, in: ...Date(), displayedComponents: .date)
                            .datePickerStyle(.graphical).padding(16)
                    }
                    Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 32) }
                        .help("后一天").keyboardShortcut(.rightArrow, modifiers: .command)
                        .disabled(Calendar.current.startOfDay(for: date) >= Calendar.current.startOfDay(for: Date()))
                    Button("今天") { date = Date() }
                        .font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.chip, in: Capsule())
                }
                .buttonStyle(.plain)
                if let openDiary {
                    Button(action: openDiary) {
                        Label("写这一天", systemImage: "square.and.pencil")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 15).padding(.vertical, 11)
                            .foregroundStyle(Color.ctaText)
                            .background(Color.ctaBackground, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                ForEach(week, id: \.self) { day in
                    let selected = Calendar.current.isDate(day, inSameDayAs: date)
                    let today = Calendar.current.isDateInToday(day)
                    let hasRecord = recordedDays.contains(ActivitySession.dayKey(for: day))
                    Button { date = day } label: {
                        HStack(spacing: 12) {
                            Text(day.formatted(.dateTime.day()))
                                .font(.system(size: 23, weight: selected ? .semibold : .regular, design: .rounded))
                            VStack(alignment: .leading, spacing: 7) {
                                Text(today ? "今天" : day.formatted(.dateTime.weekday(.abbreviated)))
                                    .font(.system(size: 10, weight: .medium))
                                Capsule().fill(hasRecord ? (selected ? Color.white.opacity(0.8) : Color.riverAmethyst.opacity(0.55)) : Color.secondaryInk.opacity(0.15))
                                    .frame(width: hasRecord ? 18 : 7, height: 3)
                            }
                        }
                        .foregroundStyle(selected ? .white : Color.secondaryInk)
                        .frame(maxWidth: .infinity).frame(height: 61)
                        .background(selected ? Color.riverAmethyst : Color.strongSurface.opacity(0.55), in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(selected ? .clear : Color.ink.opacity(0.06), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(day > Date())
                    .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(.bottom, 4)
        .onChange(of: date) { showsCalendar = false }
    }

    private func shift(_ days: Int) {
        if let value = Calendar.current.date(byAdding: .day, value: days, to: date) { date = value }
    }
}
