import AppKit
import SwiftUI

private enum IngestionSourceSetting: Equatable {
    case health, chrome, notes, screenTime
}

struct RecordingSettingsView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore
    @State private var showsClearActivityConfirmation = false
    @State private var pendingRetentionDays: Int?

    var body: some View {
        SettingsPage {
            autoRecordSection
            dailyCaptureSection
            footprintSection
            baselineSection
        }
        .confirmationDialog("要清除全部实时足迹吗？", isPresented: $showsClearActivityConfirmation, titleVisibility: .visible) {
            Button("清除实时足迹", role: .destructive) { activity.clearActivity() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除本机保存的 macOS 实时片段，项目数据的每日汇总不会受影响。")
        }
        .confirmationDialog(
            "立即清理保留期限外的本机记录？",
            isPresented: Binding(
                get: { pendingRetentionDays != nil },
                set: { if !$0 { pendingRetentionDays = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let days = pendingRetentionDays {
                Button("删除并仅保留最近 \(days) 天", role: .destructive) {
                    ingestion.setRetention(days: days)
                    pendingRetentionDays = nil
                }
            }
            Button("取消", role: .cancel) { pendingRetentionDays = nil }
        } message: {
            if let days = pendingRetentionDays {
                Text("这会立即且不可撤销地删除每日混合采集兼容库中早于最近 \(days) 天的日记录、健康数据、浏览记录、采集活动片段、快记和 AI 结果。V2 原始事实与分析存档、macOS 实时足迹文件不受此期限控制。")
            }
        }
    }

    // MARK: 自动记录

    private var autoRecordSection: some View {
        SettingsGroup(title: "自动记录", detail: "只在应用切换、睡眠、锁屏或退出时保存片段，不做固定轮询。") {
            RiverPanel {
                RiverPanelRow(
                    title: "记录状态",
                    detail: activity.isTracking ? "正在保存应用切换片段" : "实时记录已暂停",
                    systemImage: "waveform.path.ecg"
                ) {
                    StatusBadge(activity.isTracking ? "已开启" : "未开启", tone: activity.isTracking ? .positive : .neutral)
                }

                RiverPanelRow(title: "记录窗口标题", detail: "关闭后只记录应用名") {
                    Toggle("记录窗口标题", isOn: Binding(
                        get: { activity.capturesTitles },
                        set: { activity.setCapturesTitles($0) }
                    ))
                    .toggleStyle(.switch)
                    .tint(AppTheme.accent)
                    .labelsHidden()
                }

                if activity.capturesTitles {
                    RiverPanelRow(title: "辅助功能权限", detail: activity.accessibilityGranted ? "已允许读取窗口标题。" : "读取窗口标题需要辅助功能权限。") {
                        Button(activity.accessibilityGranted ? "刷新" : "打开权限") { activity.requestAccessibility() }
                            .buttonStyle(.plain)
                            .smallAction()
                    }
                }

                RiverPanelRow(title: "按时段暂停记录", detail: activity.pauseScheduleEnabled ? activity.pauseWindowLabel : "暂停期间不开新片段") {
                    Toggle("按时段暂停记录", isOn: Binding(
                        get: { activity.pauseScheduleEnabled },
                        set: { activity.setPauseSchedule(enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                    .tint(AppTheme.accent)
                    .labelsHidden()
                }

                if activity.pauseScheduleEnabled {
                    HStack(spacing: AppSpacing.md) {
                        DatePicker(
                            "开始",
                            selection: Binding(
                                get: { pauseDate(activity.pauseStartMinutes) },
                                set: { activity.setPauseSchedule(enabled: true, startMinutes: pauseMinutes($0)) }
                            ),
                            displayedComponents: [.hourAndMinute]
                        )
                        .labelsHidden()

                        DatePicker(
                            "结束",
                            selection: Binding(
                                get: { pauseDate(activity.pauseEndMinutes) },
                                set: { activity.setPauseSchedule(enabled: true, endMinutes: pauseMinutes($0)) }
                            ),
                            displayedComponents: [.hourAndMinute]
                        )
                        .labelsHidden()
                        Spacer()
                    }
                    .padding(.vertical, AppSpacing.sm)
                }

                RiverPanelRow(title: "本机占用", detail: activity.storageSummary, showsDivider: false) {
                    HStack(spacing: AppSpacing.sm) {
                        Button(activity.isTracking ? "停止记录" : "开始记录") {
                            if activity.isTracking {
                                activity.stopTracking()
                            } else {
                                activity.startTracking()
                            }
                        }
                        .buttonStyle(.plain)
                        .smallAction(dark: true)

                        Button("清除实时足迹") { showsClearActivityConfirmation = true }
                            .buttonStyle(.plain)
                            .smallAction()
                    }
                }
            }
        }
    }

    // MARK: 每日混合采集

    private var dailyCaptureSection: some View {
        SettingsGroup(title: "每日混合采集", detail: "到这个时间会采集当天数据；同一天仅自动生成一次总结。") {
            RiverPanel {
                RiverPanelRow(
                    title: "采集状态",
                    detail: ingestion.sourceURL?.path ?? "未选择 iOS 数据源，默认读取 iCloud 河流日记目录"
                ) {
                    if ingestion.isRunning {
                        StatusBadge("采集中", tone: .attention)
                    } else if ingestion.enabled {
                        StatusBadge("每日 \(ingestion.captureTimeLabel())", tone: .positive)
                    } else {
                        StatusBadge("已关闭")
                    }
                }

                RiverPanelRow(title: "自动采集与 AI 分析", detail: captureTimingDetail) {
                    HStack(spacing: AppSpacing.sm) {
                        Toggle("自动采集与 AI 分析", isOn: Binding(
                            get: { ingestion.enabled },
                            set: { ingestion.setEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        .tint(AppTheme.accent)
                        .labelsHidden()

                        DatePicker(
                            "采集时间",
                            selection: Binding(
                                get: {
                                    Calendar.current.date(
                                        bySettingHour: ingestion.captureHour,
                                        minute: ingestion.captureMinute,
                                        second: 0,
                                        of: Date()
                                    ) ?? Date()
                                },
                                set: { newValue in
                                    let cal = Calendar.current
                                    ingestion.setCaptureTime(
                                        hour: cal.component(.hour, from: newValue),
                                        minute: cal.component(.minute, from: newValue)
                                    )
                                }
                            ),
                            displayedComponents: [.hourAndMinute]
                        )
                        .labelsHidden()
                    }
                }

                RiverPanelRow(title: "采集来源", detail: "开关即时保存，并从下一次采集起生效") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: AppSpacing.md)], alignment: .leading, spacing: AppSpacing.sm) {
                        Toggle("健康与快记", isOn: sourceBinding(.health)).toggleStyle(.switch).tint(AppTheme.accent).font(AppTypography.label())
                        Toggle("Chrome 浏览", isOn: sourceBinding(.chrome)).toggleStyle(.switch).tint(AppTheme.accent).font(AppTypography.label())
                        Toggle("备忘录", isOn: sourceBinding(.notes)).toggleStyle(.switch).tint(AppTheme.accent).font(AppTypography.label())
                        Toggle("实时足迹汇总", isOn: sourceBinding(.screenTime)).toggleStyle(.switch).tint(AppTheme.accent).font(AppTypography.label())
                    }
                    .frame(width: 340, alignment: .leading)
                }

                RiverPanelRow(title: "保留期限", detail: "只清理每日混合采集兼容库；V2 原始事实不受此期限控制。") {
                    Picker("保留最近", selection: Binding(
                        get: { ingestion.retentionDays },
                        set: { days in
                            if RetentionPolicy.requiresConfirmation(
                                currentDays: ingestion.retentionDays,
                                requestedDays: days
                            ) {
                                pendingRetentionDays = days
                            } else {
                                ingestion.setRetention(days: days)
                            }
                        }
                    )) {
                        Text("永久保留").tag(0)
                        Text("最近 90 天").tag(90)
                        Text("最近 180 天").tag(180)
                        Text("最近 365 天").tag(365)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 150)
                }

                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    if let record = ingestion.dailyRecord {
                        Text("今日记录：\(record.summary)")
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.secondaryInk)
                    }
                    if let date = ingestion.lastIngestedAt {
                        Text("最近采集：\(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.tertiaryInk)
                    }
                    if let date = ingestion.lastSourceModifiedAt {
                        Text("源文件更新：\(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.tertiaryInk)
                    }
                    if let error = ingestion.lastError {
                        Text(error)
                            .font(AppTypography.metadata())
                            .foregroundStyle(AppTheme.error)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(ingestion.lastStatus)
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.tertiaryInk)
                    }

                    HStack(spacing: AppSpacing.sm) {
                        Button("选择数据源") { chooseIngestionSource() }
                            .buttonStyle(.plain)
                            .smallAction()
                        Button("立即采集") { ingestion.captureNow() }
                            .buttonStyle(.plain)
                            .smallAction(dark: true)
                        Spacer()
                    }
                    .padding(.top, AppSpacing.xs)
                }
                .padding(.top, AppSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 采集快照导出

    private var footprintSection: some View {
        SettingsGroup(title: "采集快照导出", detail: "把清洗后的采集结果写成 JSON，便于本机查看或交接。") {
            RiverPanel {
                RiverPanelRow(
                    title: "导出位置",
                    detail: ingestion.exportURL?.path ?? "检测到项目目录时会自动导出 data/ios-user-data.json",
                    showsDivider: false
                ) {
                    HStack(spacing: AppSpacing.sm) {
                        Button(ingestion.exportURL == nil ? "开启导出" : "更改位置") {
                            chooseIngestionExportPath()
                        }
                        .buttonStyle(.plain)
                        .smallAction()

                        Button("立即导出") { ingestion.exportDailyRecord() }
                            .buttonStyle(.plain)
                            .smallAction(dark: true)
                            .disabled(ingestion.dailyRecord == nil)

                        if ingestion.exportURL != nil {
                            Button("停止导出") { ingestion.clearExportPath() }
                                .buttonStyle(.plain)
                                .smallAction()
                        }
                    }
                }

                if let message = ingestion.exportMessage {
                    Text(message)
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.secondaryInk)
                        .padding(.top, AppSpacing.sm)
                }
            }
        }
    }

    // MARK: 日记基础快照

    private var baselineSection: some View {
        SettingsGroup(title: "日记基础快照", detail: "连接 data.json 后，主页和足迹会读取自动记录结果。") {
            RiverPanel {
                RiverPanelRow(
                    title: store.externalSourceURL?.path ?? "当前使用应用内置快照",
                    detail: baselineDetail,
                    showsDivider: false
                ) {
                    HStack(spacing: AppSpacing.sm) {
                        Button("连接 data.json") { connectSource() }
                            .buttonStyle(.plain)
                            .smallAction(dark: true)
                        Button("重新读取") { store.reloadExternalSnapshot() }
                            .buttonStyle(.plain)
                            .smallAction()
                        if store.externalSourceURL != nil {
                            Button("断开") { store.disconnectExternalSnapshot() }
                                .buttonStyle(.plain)
                                .smallAction()
                        }
                    }
                }

                if let error = store.externalSourceError {
                    Text(error)
                        .font(AppTypography.metadata())
                        .foregroundStyle(AppTheme.error)
                        .padding(.top, AppSpacing.sm)
                }
            }
        }
    }

    private var captureTimingDetail: String {
        ingestion.enabled ? "已开启，每天 \(ingestion.captureTimeLabel())" : "已关闭，不会自动采集"
    }

    private var baselineDetail: String {
        if let modified = store.externalSourceModifiedAt {
            return "最近自动读取：\(modified.formatted(date: .abbreviated, time: .shortened))"
        }
        return store.externalSourceURL == nil ? "尚未连接，主页使用内置快照" : "已连接"
    }

    private func pauseDate(_ minutes: Int) -> Date {
        Calendar.current.date(
            bySettingHour: minutes / 60,
            minute: minutes % 60,
            second: 0,
            of: Date()
        ) ?? Date()
    }

    private func pauseMinutes(_ date: Date) -> Int {
        Calendar.current.dateComponents([.hour, .minute], from: date).hour! * 60
            + Calendar.current.dateComponents([.hour, .minute], from: date).minute!
    }

    private func sourceBinding(_ source: IngestionSourceSetting) -> Binding<Bool> {
        Binding(
            get: {
                switch source {
                case .health: ingestion.collectsHealth
                case .chrome: ingestion.collectsChrome
                case .notes: ingestion.collectsNotes
                case .screenTime: ingestion.collectsScreenTime
                }
            },
            set: { value in
                ingestion.setSourceOptions(
                    health: source == .health ? value : ingestion.collectsHealth,
                    chrome: source == .chrome ? value : ingestion.collectsChrome,
                    notes: source == .notes ? value : ingestion.collectsNotes,
                    screenTime: source == .screenTime ? value : ingestion.collectsScreenTime
                )
            }
        )
    }

    private func chooseIngestionSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "选择 iOS 导出的 river-diary-user-data.json"
        if panel.runModal() == .OK, let url = panel.url {
            ingestion.connectSource(to: url)
        }
    }

    private func chooseIngestionExportPath() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "ios-user-data.json"
        panel.message = "选择清洗后的采集快照保存位置"
        if panel.runModal() == .OK, let url = panel.url {
            ingestion.setExportPath(to: url)
        }
    }

    private func connectSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "选择项目数据里的 data.json"
        if panel.runModal() == .OK, let url = panel.url {
            store.connectExternalSnapshot(to: url)
        }
    }

}
