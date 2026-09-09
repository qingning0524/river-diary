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

            HStack(alignment: .top, spacing: 20) {
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            brand

            VStack(alignment: .leading, spacing: 8) {
                ForEach(AppDestination.allCases) { item in
                    navigationButton(item)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 8) {
                quickCapture
                navigationStatus("采集", ingestion.enabled ? ingestion.captureTimeLabel() : "关闭", ready: ingestion.enabled)
                navigationStatus("足迹", activity.isTracking ? "开启" : "关闭", ready: activity.isTracking)
                navigationStatus("AI", ai.analysisReady ? "就绪" : ai.isEnabled ? "未连" : "关闭", ready: ai.analysisReady)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.07), radius: 22, x: 0, y: 14)
    }

    private var contentTopBar: some View {
        HStack(spacing: 14) {
            NavigationDateCard(selection: $selectedDate)
                .frame(maxWidth: 368, alignment: .leading)

            Spacer(minLength: 12)
            themeButton
        }
    }

    private var brand: some View {
        HStack(spacing: 8) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ctaText)
                .frame(width: 32, height: 32)
                .background(Color.ctaBackground, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("River Diary")
                    .font(.system(size: 14, weight: .semibold))
                Text("生活节律")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var quickCapture: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快记")
                .font(.caption.smallCaps())
                .foregroundStyle(.tertiary)

            HStack(spacing: 7) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.ctaText)
                    .frame(width: 24, height: 24)
                    .background(Color.ctaBackground, in: Circle())

                TextField("一句话", text: $quickCaptureText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .lineLimit(1...3)
                    .onSubmit(saveQuickCapture)
            }
            .padding(7)
            .background(Color.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                saveQuickCapture()
            } label: {
                Text("保留到今天")
                    .font(.caption2.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .primaryCTA()
        }
    }

    private var themeButton: some View {
        Button {
            isDimmed.toggle()
        } label: {
            Image(systemName: isDimmed ? "sun.max" : "moon")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.secondaryInk)
                .frame(width: 32, height: 32)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(isDimmed ? "切换到浅色" : "切换到深色")
    }

    private func navigationButton(_ item: AppDestination) -> some View {
        let isSelected = destination == item
        let isHovered = hoveredDestination == item

        return Button {
            destination = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.ctaText : Color.secondaryInk)
                    .frame(width: 24, height: 24)
                    .background(isSelected ? Color.ctaBackground : Color.chip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                Text(item.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.ink : Color.secondaryInk)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let badge = badge(for: item) {
                    Text(badge)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.chip, in: Capsule())
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.strongSurface)
                        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.chip)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private func navigationStatus(_ title: String, _ value: String, ready: Bool) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(ready ? Color(hex: "#2C8158") : Color(hex: "#B26B00"))
                .frame(width: 5, height: 5)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
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
