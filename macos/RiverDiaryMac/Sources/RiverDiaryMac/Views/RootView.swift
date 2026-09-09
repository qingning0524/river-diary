import SwiftUI

struct RootView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore

    @State private var destination: AppDestination = .today
    @State private var timeSection: TimeSection = .river
    @State private var memorySection: MemorySection = .search
    @State private var systemSection: SystemSection = .controls
    @State private var selectedDate = Date()
    @State private var quickCaptureText = ""
    @AppStorage("appearance.prefersDark") private var isDimmed = false
    @State private var hoveredDestination: AppDestination?
    @AppStorage("privacy.appLockEnabled") private var appLockEnabled = false
    @State private var isLocked = false
    @State private var lockMessage = ""

    var body: some View {
        ZStack {
            VisualBackground()

            HStack(alignment: .top, spacing: 18) {
                sidebar
                    .frame(width: AppLayout.sidebarWidth, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 16) {
                    contentTopBar

                    Group {
                        if let error = store.loadError {
                            errorView(error)
                        } else {
                            selectedView
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(destination)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 10)),
                        removal: .opacity
                    ))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(AppLayout.outerPadding)
        }
        .preferredColorScheme(isDimmed ? .dark : .light)
        .animation(.easeOut(duration: 0.22), value: destination)
        .animation(.easeOut(duration: 0.22), value: isDimmed)
        .overlay {
            if appLockEnabled && isLocked {
                AppLockGate(isLocked: isLocked, message: lockMessage) {
                    unlockApp()
                }
            }
        }
        .onAppear {
            if appLockEnabled { isLocked = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.checkExternalSnapshotChanged()
            if appLockEnabled && isLocked == false {
                isLocked = true
            }
        }
    }

    private func unlockApp() {
        AppLock.unlock { success, message in
            isLocked = !success
            lockMessage = message
        }
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.bottom, 13)

            flowDivider
                .padding(.bottom, 11)

            VStack(alignment: .leading, spacing: 5) {
                Text("旅程")
                    .font(.caption2.smallCaps().weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 9)

                ForEach(AppDestination.allCases) { item in
                    navigationButton(item)
                }
            }
            .padding(.bottom, 12)

            flowDivider
                .padding(.bottom, 10)

            statusSection

            Spacer(minLength: 12)

            quickCapture

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 9, weight: .medium))
                Text("记录只在这台 Mac 上整理")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 10)
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.surface)
                .overlay(
                    RadialGradient(
                        colors: [Color.riverAmethyst.opacity(0.12), .clear],
                        center: UnitPoint(x: 0.05, y: 0.02),
                        startRadius: 0,
                        endRadius: 320
                    )
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(isDimmed ? 0.12 : 0.9), Color.white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(isDimmed ? 0.05 : 0.09), radius: 3, x: 0, y: 1)
        .shadow(color: .black.opacity(0.05), radius: 24, x: 0, y: 16)
    }

    private var flowDivider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color.ink.opacity(0), Color.ink.opacity(0.09), Color.ink.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            BrandMark(size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("River Diary")
                    .font(.ui(14, weight: .semibold))
                Text("生活节律")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text("此刻")
                    .font(.caption2.smallCaps().weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            navigationStatus(
                "采集",
                icon: "waveform.badge.magnifyingglass",
                value: ingestion.enabled ? ingestion.captureTimeLabel() : "关闭",
                ready: ingestion.enabled
            )
            navigationStatus(
                "足迹",
                icon: "location.viewfinder",
                value: activity.isTracking ? "开启" : "关闭",
                ready: activity.isTracking
            )
            navigationStatus(
                "AI",
                icon: "brain",
                value: ai.analysisReady ? "就绪" : ai.isEnabled ? "未连" : "关闭",
                ready: ai.analysisReady
            )
        }
    }

    private var quickCapture: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快记")
                .font(.caption2.smallCaps().weight(.semibold))
                .foregroundStyle(.tertiary)

            HStack(spacing: 7) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(
                        LinearGradient.river(),
                        in: Circle()
                    )

                TextField("一句话", text: $quickCaptureText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .lineLimit(1...3)
                    .onSubmit(saveQuickCapture)
            }
            .padding(7)
            .background(Color.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.border.opacity(0.6), lineWidth: 1)
            )

            Button {
                saveQuickCapture()
            } label: {
                Text("保留到今天")
                    .font(.caption2.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .primaryCTA()
        }
    }

    private var contentTopBar: some View {
        HStack(spacing: 14) {
            NavigationDateCard(selection: $selectedDate)
                .frame(maxWidth: 400, alignment: .leading)

            Spacer(minLength: 12)

            themeButton
        }
    }

    private var themeButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                isDimmed.toggle()
            }
        } label: {
            Image(systemName: isDimmed ? "sun.max.fill" : "moon.stars.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.secondaryInk)
                .frame(width: 32, height: 32)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.border, lineWidth: 1)
                )
        }
        .buttonStyle(.softPress)
        .help(isDimmed ? "切换到浅色" : "切换到深色")
    }

    private func navigationButton(_ item: AppDestination) -> some View {
        let isSelected = destination == item
        let isHovered = hoveredDestination == item

        return Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                destination = item
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : Color.secondaryInk)
                    .frame(width: 26, height: 26)
                    .background(
                        isSelected ? Color.white.opacity(0.20) : Color.chip,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                Text(item.title)
                    .font(.ui(13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .white : Color.ink)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let badge = badge(for: item) {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.ctaText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.ctaBackground.opacity(0.9), in: Capsule())
                } else if !isSelected {
                    Text("⌘\(item.shortcutNumber)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .opacity(isHovered ? 1 : 0.55)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 37)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient.river())
                        .shadow(color: Color.riverAmethyst.opacity(0.38), radius: 10, x: 0, y: 5)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.chip)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.softPress)
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.15)) {
                if isHovered {
                    hoveredDestination = item
                } else if hoveredDestination == item {
                    hoveredDestination = nil
                }
            }
        }
        .keyboardShortcut(KeyEquivalent(Character("\(item.shortcutNumber)")), modifiers: .command)
        .help(item.caption)
    }

    private func badge(for item: AppDestination) -> String? {
        switch item {
        case .today:
            return store.autoDraftPaused ? "暂停" : nil
        case .memory:
            let count = store.quickCaptures.values.reduce(0) { $0 + $1.count }
            return count > 0 ? "\(min(count, 99))" : nil
        default:
            return nil
        }
    }

    private func navigationStatus(_ title: String, icon: String, value: String, ready: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.chip, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(ready ? Color(hex: "#2C8158") : Color(hex: "#B26B00"))
                    .frame(width: 5, height: 5)
                Text(value)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var selectedView: some View {
        switch destination {
        case .today:
            TodayView(store: store, activity: activity, ai: ai, selectedDate: $selectedDate)
        case .time:
            TimeFlowView(
                store: store,
                activity: activity,
                ai: ai,
                selectedDate: $selectedDate,
                section: $timeSection
            )
        case .memory:
            MemoryFlowView(
                ai: ai,
                entries: store.entries,
                quickCaptures: store.quickCaptures.values.flatMap(\.self),
                section: $memorySection
            ) { date in
                selectedDate = date
                destination = .today
            }
        case .insight:
            InsightFlowView(store: store, activity: activity, ai: ai, selectedDate: $selectedDate)
        case .system:
            SystemFlowView(
                store: store,
                activity: activity,
                ai: ai,
                ingestion: ingestion,
                selectedDate: $selectedDate,
                section: $systemSection
            )
        }
    }

    private func saveQuickCapture() {
        let text = quickCaptureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addQuickCapture(text, for: selectedDate)
        quickCaptureText = ""
    }

    private func errorView(_ message: String) -> some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("数据加载失败", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 560)
    }
}
