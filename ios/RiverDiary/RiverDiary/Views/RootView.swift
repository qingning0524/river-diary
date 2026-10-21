import RiverDiaryCore
import SwiftUI

struct RootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var coordinator = RiverAppCoordinator()
    @EnvironmentObject private var node: RiverNodeStore
    @EnvironmentObject private var account: RiverAccountSessionStore
    @EnvironmentObject private var themeStore: RiverThemeStore
    @StateObject private var drafts = RiverLocalDraftStore()
    @State private var qaLoginCompleted = false
    @State private var journalFeedback: RiverFeedback?

    private var activeTheme: RiverThemeContext { themeStore.context(for: colorScheme) }

    private var pendingCount: Int {
        (node.database?.sharedUserRecords ?? []).filter { record in
            (record.kind == .pendingConfirmation && record.status == "pending")
                || (record.kind == .habitCard && ["bundled", "shown"].contains(record.status))
        }.count
    }

    private var isQADesignSession: Bool {
        #if DEBUG
        return Bundle.main.bundleIdentifier == "studio.riverdiary.ios.qa"
            && ProcessInfo.processInfo.arguments.contains("--riverdiary-qa-visual-session")
        #else
        return false
        #endif
    }

    private var isQALoginPreview: Bool {
        #if DEBUG
        return !qaLoginCompleted && Bundle.main.bundleIdentifier == "studio.riverdiary.ios.qa" && (ProcessInfo.processInfo.arguments.contains("--riverdiary-qa-login-preview") || ProcessInfo.processInfo.arguments.contains("--riverdiary-qa-login-code-preview"))
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
        if isQALoginPreview {
            AccountLoginView()
        } else if node.database != nil || isQADesignSession {
        VStack(spacing: 0) {
        RiverSharedDateHeader()
        TabView(selection: $coordinator.selectedTab) {
                    NavigationStack(path: $coordinator.timelinePath) {
                        RiverAutomaticTodayView()
                            .navigationDestination(for: RiverAppRoute.self) { RiverIOSRouteDestination(route: $0) }
                    }.tag(RiverAppTab.timeline).tabItem { EmptyView() }
                    NavigationStack(path: $coordinator.footprintsPath) {
                        RiverFootprintsView()
                            .navigationDestination(for: RiverAppRoute.self) { RiverIOSRouteDestination(route: $0) }
                    }.tag(RiverAppTab.footprints).tabItem { EmptyView() }
                    NavigationStack(path: $coordinator.confirmationsPath) { RiverConfirmationsView()
                        .navigationDestination(for: RiverAppRoute.self) { RiverIOSRouteDestination(route: $0) }
                    }.tag(RiverAppTab.confirmations).tabItem { EmptyView() }
                    NavigationStack(path: $coordinator.riverPath) {
                        RiverUnderstandingView()
                            .navigationDestination(for: RiverAppRoute.self) { RiverIOSRouteDestination(route: $0) }
                    }.tag(RiverAppTab.river).tabItem { EmptyView() }
                    NavigationStack(path: $coordinator.mePath) {
                        RiverMemoryHomeView()
                            .navigationDestination(for: RiverAppRoute.self) { RiverIOSRouteDestination(route: $0) }
                    }.tag(RiverAppTab.me).tabItem { EmptyView() }
        }
        }
        .environment(\.riverUsesSharedHeader, true)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !(coordinator.selectedTab == .river && coordinator.riverComposerFocused) {
                RiverIOSBottomBar(selection: $coordinator.selectedTab, pendingCount: pendingCount)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(activeTheme.canvas.ignoresSafeArea())
        .sheet(item: $coordinator.journalPresentation) { presentation in
            RiverJournalComposerView(date: presentation.date) {
                coordinator.journalSaveRevision &+= 1
                node.objectWillChange.send()
                journalFeedback = .success("日记已保存在本机。")
            }
        }
        .riverFeedback($journalFeedback)
        .environmentObject(coordinator)
        .environmentObject(drafts)
        } else {
            LocalLibraryUnavailableView(
                message: node.initializationError ?? "本机资料库暂时无法打开。"
            ) {
                node.retryOpen()
            }
        }
        }
        .task {
            #if DEBUG
            RiverModernQAFixtures.seedIfRequested(node: node)
            if isQADesignSession, let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--riverdiary-qa-page=") }), let page = RiverAppTab(rawValue: String(argument.dropFirst("--riverdiary-qa-page=".count))) { coordinator.selectedTab = page }
            if Bundle.main.bundleIdentifier == "studio.riverdiary.ios.qa", ProcessInfo.processInfo.arguments.contains("--riverdiary-qa-settings-preview") {
                coordinator.selectedTab = .me
                coordinator.mePath = [.settings]
            }
            #endif
        }
        .onChange(of: account.isSignedIn) { _, signedIn in if signedIn { qaLoginCompleted = true } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { drafts.flush() } else { coordinator.followDayBoundaryIfNeeded() } }
        .environment(\.riverTheme, activeTheme)
        .tint(activeTheme.accentText)
        .background(activeTheme.canvas.ignoresSafeArea())

    }


}

private struct LocalLibraryUnavailableView: View {
    @Environment(\.riverTheme) private var theme
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(theme.warning)
            Text("本机资料暂时打不开")
                .font(theme.titleFont)
                .foregroundStyle(theme.ink)
            Text("你的日记仍在本机。请先重试；如果持续失败，不要新建空库覆盖，先导出/救援。")
                .font(theme.detailFont)
                .foregroundStyle(theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(theme.ink)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
            Button("重试打开本机资料", action: retry)
                .font(.body.weight(.semibold))
                .frame(minHeight: 44)
                .padding(.horizontal, 18)
                .background(theme.accentSoft, in: Capsule())
                .foregroundStyle(theme.accentText)
        }
        .padding(24)
        .frame(maxWidth: 520, maxHeight: .infinity, alignment: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas.ignoresSafeArea())
    }
}

private struct RiverIOSBottomBar: View {
    @Environment(\.riverTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionWell
    @Binding var selection: RiverAppTab
    let pendingCount: Int

    private struct Item: Identifiable {
        let tab: RiverAppTab
        let title: String
        var id: RiverAppTab { tab }
    }

    private let items = [
        Item(tab: .timeline, title: "今天"),
        Item(tab: .footprints, title: "足迹"),
        Item(tab: .confirmations, title: "待确认"),
        Item(tab: .river, title: "River"),
        Item(tab: .me, title: "我的")
    ]

    private func symbol(for tab: RiverAppTab) -> String {
        switch tab { case .timeline: "sun.max"; case .footprints: "mappin.and.ellipse"; case .confirmations: "checklist"; case .river: "water.waves"; case .me: "person" }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let isSelected = selection == item.tab
                Button {
                    if !isSelected { RiverHaptics.selection() }
                    withAnimation(reduceMotion ? nil : .riverSpring) { selection = item.tab }
                } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: symbol(for: item.tab))
                                .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                                .frame(width: 34, height: 26)
                                .foregroundStyle(isSelected ? theme.accentText : theme.secondaryInk)
                                .background(isSelected ? theme.accentSoft.opacity(0.45) : .clear, in: Capsule())
                                .animation(reduceMotion ? nil : .riverGentle, value: isSelected)
                            if item.tab == .confirmations, pendingCount > 0 {
                                Text(pendingCount > 99 ? "99+" : "\(pendingCount)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(theme.palette.onAccent)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 15, minHeight: 15)
                                    .background(theme.accent, in: Capsule())
                                    .contentTransition(.numericText())
                                    .animation(reduceMotion ? nil : .riverGentle, value: pendingCount)
                                    .offset(x: 7, y: -5)
                            }
                        }
                        Text(item.title)
                            .font(.caption2.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? theme.accentText : theme.secondaryInk)
                            .lineLimit(1)
                    }
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(maxWidth: .infinity, minHeight: theme.tapTarget)
                    .contentShape(Rectangle())
                    .background {
                        if isSelected {
                            Color.clear.riverNeumorphic(inset: true, radius: 18)
                                .matchedGeometryEffect(id: "selected-tab", in: selectionWell)
                        }
                    }
                }
                .riverTactile()
                .accessibilityLabel(item.tab == .confirmations && pendingCount > 0
                                    ? "\(item.title)，\(pendingCount) 条待确认"
                                    : item.title)
                .accessibilityIdentifier("river.tab.\(item.tab.rawValue)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .riverNeumorphic(radius: 28)
        .padding(.horizontal, 22).padding(.bottom, 8).padding(.top, 7)
        .background(theme.canvas)
    }
}
