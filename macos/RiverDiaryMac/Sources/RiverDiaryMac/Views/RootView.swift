import SwiftUI

struct RootView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore

    @State private var flow: AppFlow = .today
    @State private var selectedDate = Date()
    @AppStorage("appearance.prefersDark") private var isDimmed = false
    @AppStorage("flow.calmMode") private var calmMode = false
    @AppStorage("privacy.appLockEnabled") private var appLockEnabled = false
    @State private var isLocked = false
    @State private var lockMessage = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 212, ideal: 236, max: 280)
        } detail: {
            detail
        }
        .preferredColorScheme(isDimmed ? .dark : .light)
        .animation(.easeOut(duration: 0.22), value: flow)
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
        List(selection: Binding(
            get: { Optional(flow) },
            set: { if let value = $0 { flow = value } }
        )) {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ctaText)
                        .frame(width: 34, height: 34)
                        .background(Color.ctaBackground, in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("River Diary")
                            .font(.headline)
                        Text("生活节律")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("河流") {
                ForEach(AppFlow.allCases) { item in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.callout.weight(.semibold))
                            Text(item.caption)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: item.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: item.accent))
                    }
                    .tag(item)
                    .contentShape(Rectangle())
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "circle.hexagongrid.fill")
                        .foregroundStyle(Color.ctaText)
                    Picker("外观", selection: $isDimmed) {
                        Text("日").tag(false)
                        Text("夜").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                statusRow
            }
            .padding(12)
            .background(.bar)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 7) {
            statusDot(ready: ingestion.enabled)
            statusDot(ready: activity.isTracking)
            statusDot(ready: ai.analysisReady)
            Spacer()
            Text("\(store.entries.count) 天")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func statusDot(ready: Bool) -> some View {
        Circle()
            .fill(ready ? Color(hex: "#2C8158") : Color(hex: "#B26B00"))
            .frame(width: 6, height: 6)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar

            Group {
                if let error = store.loadError {
                    errorView(error)
                } else {
                    selectedView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            NavigationDateCard(selection: $selectedDate)
                .frame(maxWidth: 320, alignment: .leading)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                statusPill("采集", ingestion.enabled ? "开启" : "关闭", ready: ingestion.enabled)
                statusPill("足迹", activity.isTracking ? "开启" : "关闭", ready: activity.isTracking)
                statusPill("AI", ai.analysisReady ? "就绪" : ai.isEnabled ? "未连" : "关闭", ready: ai.analysisReady)
            }

            Button {
                appLockEnabled.toggle()
            } label: {
                Image(systemName: appLockEnabled ? "lock.fill" : "lock.open")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help(appLockEnabled ? "隐私锁已开启" : "隐私锁已关闭")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.surface.opacity(0.62))
        .overlay(alignment: .bottom) { Divider().opacity(0.24) }
    }

    private func statusPill(_ title: String, _ value: String, ready: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ready ? Color(hex: "#2C8158") : Color(hex: "#B26B00"))
                .frame(width: 5, height: 5)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.ink)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.surface, in: Capsule())
        .overlay(Capsule().stroke(Color.border, lineWidth: 1))
        .fixedSize()
    }

    @ViewBuilder
    private var selectedView: some View {
        switch flow {
        case .today:
            TodayFlowView(
                store: store,
                activity: activity,
                ai: ai,
                selectedDate: $selectedDate,
                calmMode: $calmMode
            )
        case .rhythm:
            RhythmFlowView(
                store: store,
                activity: activity,
                ai: ai,
                selectedDate: $selectedDate
            )
        case .memory:
            MemoryFlowView(store: store, ai: ai, selectedDate: $selectedDate)
        case .settings:
            SettingsFlowView(store: store, activity: activity, ai: ai, ingestion: ingestion)
        }
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
        .padding(24)
    }
}
