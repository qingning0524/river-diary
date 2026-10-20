import SwiftUI

/// One catalogue shared by the sidebar, breadcrumb, Go menu and command search.
enum RiverNavigationGroup: String, CaseIterable, Identifiable {
    case everyday, reflection
    var id: String { rawValue }
    var title: String { self == .everyday ? "日常" : "记忆与回顾" }
    var destinations: [RiverDestination] {
        self == .everyday ? [.today, .timeline] : [.memory, .ask, .dailyReview]
    }
}

extension RiverDestination {
    var group: RiverNavigationGroup {
        RiverNavigationGroup.allCases.first { $0.destinations.contains(workspaceRoot) } ?? .everyday
    }
    /// Legacy routes remain valid shortcuts into the five user workspaces.
    var workspaceRoot: RiverDestination {
        switch self {
        case .timeline, .footprints, .health, .workLearn: .timeline
        case .dailyReview, .confirmations, .habitReview, .progress: .dailyReview
        default: self
        }
    }
    var isPrimaryWorkspace: Bool {
        [.today, .timeline, .memory, .ask, .dailyReview].contains(self)
    }
    var sections: [RiverDestination] {
        switch workspaceRoot {
        case .timeline: [.timeline, .footprints, .health]
        case .dailyReview: [.dailyReview, .confirmations, .habitReview, .progress]
        default: []
        }
    }
    var sectionTitle: String {
        switch self {
        case .timeline: "片刻"
        case .dailyReview: "周期回顾"
        case .habitReview: "习惯"
        default: title
        }
    }
    var searchKeywords: String {
        switch self {
        case .today: "today 首页 今日"
        case .timeline: "timeline 时间线 日记 日志 写作"
        case .confirmations: "confirmations 确认 纠正 判断"
        case .ask: "ask river 询问 提问 对话"
        case .memory: "memory 搜索 收藏 档案"
        case .dailyReview: "review 复盘 每日"
        case .habitReview: "habit 习惯 规律"
        case .progress: "progress 对比 趋势"
        case .health: "health 睡眠 心情 运动"
        case .workLearn: "work learn 学习 工作 项目"
        case .footprints: "footprints 地点 位置 地图"
        case .sources: "sources 权限 采集 设备"
        case .database: "database 原始数据 证据"
        }
    }
}

/// Page history deliberately leaves the shared date and journal draft untouched.
struct RiverNavigationHistory {
    private(set) var entries: [RiverDestination]
    private(set) var index = 0
    init(initial: RiverDestination = .today) { entries = [initial] }
    var current: RiverDestination { entries[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < entries.count }

    mutating func visit(_ destination: RiverDestination) {
        guard destination != current else { return }
        entries = Array(entries.prefix(index + 1))
        entries.append(destination)
        // Bound a long-running desktop session without affecting normal traversal.
        if entries.count > 100 { entries.removeFirst() }
        index = entries.count - 1
    }
    mutating func back() -> RiverDestination? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }
    mutating func forward() -> RiverDestination? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }
}

/// Quiet toolbar chrome, with the same hover/focus hit area in both rail modes.
struct RiverNavigationButton: View {
    let symbol: String
    let label: String
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isEnabled ? Color.secondaryInk : Color.tertiaryInk.opacity(0.45))
                .frame(width: 30, height: 32)
                .background(hovered && isEnabled ? Color.ink.opacity(0.06) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: AppMotion.quick), value: hovered)
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct RiverWorkspaceEmbeddedKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var riverWorkspaceEmbedded: Bool {
        get { self[RiverWorkspaceEmbeddedKey.self] }
        set { self[RiverWorkspaceEmbeddedKey.self] = newValue }
    }
}

/// One lightweight header for a workspace; child pages only keep contextual controls.
struct RiverWorkspaceHeader: View {
    let destination: RiverDestination
    let pendingCount: Int
    let onSelect: (RiverDestination) -> Void

    private var tabs: some View {
        RiverSegmentedPicker(title: "分区", selection: Binding(
            get: { destination }, set: onSelect
        ), options: destination.sections) { item in
            item == .confirmations && pendingCount > 0 ? "待确认 · \(pendingCount)" : item.sectionTitle
        }
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 22) {
                Text(destination == .timeline ? "生活有迹，回头可见。" : destination.workspaceRoot.title).font(AppTypography.briefLead()).foregroundStyle(Color.ink).fixedSize()
                Spacer(minLength: 12)
                tabs.fixedSize()
            }
            VStack(alignment: .leading, spacing: 14) {
                Text(destination == .timeline ? "生活有迹，回头可见。" : destination.workspaceRoot.title).font(AppTypography.briefLead()).foregroundStyle(Color.ink)
                tabs
            }
        }
        .padding(.horizontal, AppSpacing.page).padding(.top, 22).padding(.bottom, 16)
        .background(Color.workspace)
        .overlay(alignment: .bottom) { RiverRule() }
    }
}
