import SwiftUI

private struct SharedHeaderKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var riverUsesSharedHeader: Bool { get { self[SharedHeaderKey.self] } set { self[SharedHeaderKey.self] = newValue } }
}
struct RiverNeumorphicSurface: ViewModifier {
    @Environment(\.riverTheme) private var theme
    var inset = false
    var radius: CGFloat = 23
    var referenceGradient = false
    var surfaceColor: Color? = nil
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = theme.colorScheme == .dark
        let small = radius < 20
        let offset: CGFloat = small ? 3.5 : referenceGradient ? 8 : 6
        let blur: CGFloat = small ? 5 : referenceGradient ? 9 : 7
        let shadow = dark ? Color.black.opacity(0.35) : Color(hex: "#A6B4C8").opacity(small ? 0.35 : 0.4)
        content.background {
            if inset {
                shape.fill((surfaceColor ?? theme.canvas)
                    .shadow(.inner(color: shadow, radius: 3, x: 2.5, y: 2.5))
                    .shadow(.inner(color: dark ? .white.opacity(0.06) : .white.opacity(0.9), radius: 3, x: -2.5, y: -2.5)))
            } else {
                shape.fill(LinearGradient(colors: referenceGradient && !dark ? [Color(hex: "#F7FAFE"), Color(hex: "#E5EBF2")] : [surfaceColor ?? theme.canvas, surfaceColor ?? theme.canvas], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: shadow, radius: blur, x: offset, y: offset)
                    .shadow(color: dark ? .white.opacity(0.025) : .white.opacity(0.95), radius: blur, x: -offset, y: -offset)
                    .overlay { if !referenceGradient { shape.strokeBorder(dark ? .white.opacity(0.06) : .white.opacity(0.6), lineWidth: 0.5) } }
            }
        }
    }
}
extension View { func riverNeumorphic(inset: Bool = false, radius: CGFloat = 23, referenceGradient: Bool = false, surfaceColor: Color? = nil) -> some View { modifier(RiverNeumorphicSurface(inset: inset, radius: radius, referenceGradient: referenceGradient, surfaceColor: surfaceColor)) } }

struct RiverSharedDateHeader: View {
    @Environment(\.riverTheme) private var theme
    @EnvironmentObject private var coordinator: RiverAppCoordinator
    @State private var showsCalendar = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { brand; Spacer(minLength: 6); dateButton }
                VStack(alignment: .leading, spacing: 12) { brand; dateButton }
            }
        }.padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 8)
            .sheet(isPresented: $showsCalendar) {
                NavigationStack {
                    VStack(spacing: 0) {
                    DatePicker("选择全局日期", selection: $coordinator.selectedDate, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        Spacer(minLength: 0)
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(theme.canvas)
                        .navigationTitle("全局日期").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { coordinator.selectedDate = Calendar.current.startOfDay(for: coordinator.selectedDate); showsCalendar = false } } }
                }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
    }
    private var brand: some View { Text("RIVER DIARY").font(.system(size: 12, weight: .bold)).tracking(1.3).foregroundStyle(theme.secondaryInk).fixedSize() }
    private var dateButton: some View {
        Button { showsCalendar = true } label: {
            HStack(spacing: 6) { Text(coordinator.selectedDate.formatted(.dateTime.month().day().weekday(.abbreviated))).font(.caption.weight(.semibold)); Image(systemName: "chevron.down").font(.system(size: 10)) }.foregroundStyle(theme.ink).padding(.horizontal, 12).frame(minHeight: 44).riverNeumorphic(radius: 15)
        }.riverTactile().accessibilityIdentifier("river.global.date").accessibilityLabel("选择全局日期，\(RiverIOSProjection.dayKey(coordinator.selectedDate))")
    }
}

/// A consistent heading inside each page’s scroll content, independent of the fixed date row.
struct RiverScrollingPageHeading: View {
    @Environment(\.riverTheme) private var theme
    @EnvironmentObject private var node: RiverNodeStore
    let tab: RiverAppTab
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(theme.textFont(26, relativeTo: .title2, weight: .bold)).foregroundStyle(theme.ink).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.caption).foregroundStyle(theme.secondaryInk)
            }
            Spacer(minLength: 4)
            if tab == .confirmations {
                Text("\(pendingCount) 项").font(.caption.weight(.medium)).foregroundStyle(theme.accentText).padding(8).riverNeumorphic(radius: 16)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("river.page.heading.\(tab.rawValue)")
    }
    private var title: String { switch tab { case .timeline: "今天"; case .footprints: "足迹"; case .confirmations: "待确认"; case .river: "River"; case .me: "我的" } }
    private var subtitle: String { switch tab { case .timeline: "生活自动留下线索，River 帮你整理"; case .footprints: "自动记录的时间与地点"; case .confirmations: "只核对 River 不能确定的理解"; case .river: "关于你的习惯与回忆，随时问我"; case .me: "生活记忆，慢慢积累成你的河流" } }
    private var pendingCount: Int { (node.database?.sharedUserRecords ?? []).filter { ($0.kind == .pendingConfirmation && $0.status == "pending") || ($0.kind == .habitCard && ["bundled", "shown"].contains($0.status)) }.count }
}
