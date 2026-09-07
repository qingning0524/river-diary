import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PrivacyView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore
    @State private var showsClearConfirmation = false
    @State private var showsClearActivityConfirmation = false
    @State private var showsRestoreConfirmation = false
    @State private var pendingRestoreURL: URL?
    @State private var exportMessage: String?
    @State private var optionHealth = true
    @State private var optionChrome = true
    @State private var optionNotes = true
    @State private var optionScreenTime = true
    @AppStorage("privacy.appLockEnabled") private var appLockEnabled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                sectionLabel("分析")
                modeCard

                sectionLabel("模型连接")
                aiCard

                sectionLabel("数据采集")
                autoRecordCard

                sectionLabel("健康状态")
                statusCard

                EqualWidthRow(spacing: 18) {
                    storageCard
                    controlCard
                }

                if let exportMessage {
                    Label(exportMessage, systemImage: exportMessage.contains("失败") ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(exportMessage.contains("失败") ? .red : Color(hex: "#2C8158"))
                        .frame(maxWidth: 1280, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: 1280, alignment: .leading)
            .padding(.top, 8)
            .animation(.easeOut(duration: 0.25), value: exportMessage)
            .animation(.easeOut(duration: 0.25), value: ingestion.lastStatus)
            .animation(.easeOut(duration: 0.25), value: ai.isConfigured)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            optionHealth = ingestion.collectsHealth
            optionChrome = ingestion.collectsChrome
            optionNotes = ingestion.collectsNotes
            optionScreenTime = ingestion.collectsScreenTime
        }
        .confirmationDialog(
            "要清除所有本地日记修改吗？",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除修改", role: .destructive) { store.clearLocalJournal() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清除你在 Mac 上写过的内容和先搁下的状态；随手记和原始日子不会受影响。")
        }
        .confirmationDialog(
            "要清除全部实时足迹吗？",
            isPresented: $showsClearActivityConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除实时足迹", role: .destructive) { activity.clearActivity() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除本机保存的 macOS 实时片段，项目数据的每日汇总不会受影响。")
        }
        .confirmationDialog(
            "要用这个备份替换当前数据吗？",
            isPresented: $showsRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("恢复备份", role: .destructive) { restoreBackup() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("恢复会替换当前日记、修改、快记、数据快照和已保存的实时片段。外部 data.json 连接不会删除，但恢复后会优先使用备份里保存的连接。")
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.smallCaps())
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(Color.border)
                .frame(height: 1)
        }
        .frame(maxWidth: 1280, alignment: .leading)
        .padding(.top, 6)
    }

    private var modeCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("分析模式", systemImage: "switch.2")
                    .font(.headline)

                Picker("分析模式", selection: Binding(
                    get: { ai.isEnabled },
                    set: { ai.isEnabled = $0 }
                )) {
                    Text("AI 分析模型").tag(true)
                    Text("非 AI 分析模式").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(ai.isEnabled ? "AI 分析模式会连接你选择的外部模型，用于问足迹分析。" : "非 AI 分析模式完全在本机运行，不会发送任何分析请求。")
                    .font(.caption)
                    .lineSpacing(5)
                    .foregroundStyle(.secondary)

                if ai.isEnabled && !ai.isConfigured {
                    Label("尚未连接可用的 AI 模型。请先填写 API 信息并测试连接。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .frame(maxWidth: 1280)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings").font(.caption.smallCaps()).foregroundStyle(.secondary)
            Text("设置").font(.system(size: 34, weight: .semibold)).foregroundStyle(Color.ink)
            Text("日记状态使用 AES-GCM 加密，密钥由 macOS 钥匙串保护。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 1280, alignment: .leading)
    }

    private var autoRecordCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("自动记录", systemImage: "waveform.path.ecg")
                        .font(.headline)
                    Spacer()
                    StatusBadge(activity.isTracking ? "已开启" : "未开启", tone: activity.isTracking ? .positive : .neutral)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("每日混合采集")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if ingestion.isRunning {
                            StatusBadge("采集中", tone: .attention)
                        } else if ingestion.enabled {
                            StatusBadge("每日 \(ingestion.captureTimeLabel())", tone: .positive)
                        } else {
                            StatusBadge("已关闭")
                        }
                    }

                    Text(ingestion.sourceURL?.path ?? "未选择 iOS 数据源。默认会读取 iCloud 河流日记目录。")
                        .font(.caption)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)

                    if let record = ingestion.dailyRecord {
                        Text("今日记录：\(record.summary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let date = ingestion.lastIngestedAt {
                        Text("最近采集：\(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let date = ingestion.lastSourceModifiedAt {
                        Text("源文件更新：\(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let error = ingestion.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text(ingestion.lastStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Toggle("自动采集", isOn: Binding(
                            get: { ingestion.enabled },
                            set: { ingestion.setEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        .font(.caption)

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
                        .font(.caption)

                        Button("选择数据源") { chooseIngestionSource() }
                            .buttonStyle(.plain)
                            .smallAction()
                        Button("立即采集") { ingestion.captureNow() }
                            .buttonStyle(.plain)
                            .smallAction(dark: true)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("采集来源")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 8)], alignment: .leading, spacing: 8) {
                            Toggle("健康与快记", isOn: $optionHealth).toggleStyle(.switch).font(.caption)
                            Toggle("Chrome 浏览", isOn: $optionChrome).toggleStyle(.switch).font(.caption)
                            Toggle("备忘录", isOn: $optionNotes).toggleStyle(.switch).font(.caption)
                            Toggle("实时足迹汇总", isOn: $optionScreenTime).toggleStyle(.switch).font(.caption)
                        }

                        HStack(spacing: 8) {
                            Button("保存来源设置") {
                                ingestion.setSourceOptions(
                                    health: optionHealth,
                                    chrome: optionChrome,
                                    notes: optionNotes,
                                    screenTime: optionScreenTime
                                )
                            }
                            .buttonStyle(.plain)
                            .smallAction(dark: true)

                            Picker("保留最近", selection: Binding(
                                get: { ingestion.retentionDays },
                                set: { ingestion.setRetention(days: $0) }
                            )) {
                                Text("永久保留").tag(0)
                                Text("最近 90 天").tag(90)
                                Text("最近 180 天").tag(180)
                                Text("最近 365 天").tag(365)
                            }
                            .pickerStyle(.menu)
                            .font(.caption)
                            .frame(width: 165)

                            Spacer()
                        }
                        Text("保留期会在采集后清理更早的原始记录；日记原文状态文件不受影响。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("采集快照导出（可选）")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(ingestion.exportURL?.path ?? "检测到项目目录时会自动导出 data/ios-user-data.json；也可以选择其他位置。")
                            .font(.caption)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        if let message = ingestion.exportMessage {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
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

                    Divider()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("日记基础快照（可选）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(store.externalSourceURL?.path ?? "当前使用应用内置快照。连接 data.json 后，主页和足迹会读取自动记录结果。")
                        .font(.caption)
                        .lineSpacing(5)
                        .foregroundStyle(.secondary)

                    if let modified = store.externalSourceModifiedAt {
                        Text("最近自动读取：\(modified.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let error = store.externalSourceError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }

                    HStack(spacing: 8) {
                        Button("连接 data.json") { connectSource() }
                            .buttonStyle(.plain).smallAction(dark: true)
                        Button("重新读取") { store.reloadExternalSnapshot() }
                            .buttonStyle(.plain).smallAction()
                        if store.externalSourceURL != nil {
                            Button("断开") { store.disconnectExternalSnapshot() }
                                .buttonStyle(.plain).smallAction()
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("macOS 实时足迹")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if activity.isCurrentlyPaused {
                            StatusBadge("暂停中", tone: .attention)
                        }
                    }

                    Text("只在应用切换、睡眠、锁屏或退出时保存片段；不做固定轮询。")
                        .font(.caption)
                        .lineSpacing(5)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
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
                        Spacer()
                        Text(activity.storageSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("按时段暂停记录", isOn: Binding(
                        get: { activity.pauseScheduleEnabled },
                        set: { activity.setPauseSchedule(enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                    .font(.caption)

                    if activity.pauseScheduleEnabled {
                        HStack(spacing: 10) {
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
                            Text(activity.pauseWindowLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("暂停期间不开新片段；睡眠和锁屏本来就不会计入实时足迹。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("记录窗口标题（可关闭）", isOn: Binding(
                        get: { activity.capturesTitles },
                        set: { activity.setCapturesTitles($0) }
                    ))
                    .toggleStyle(.switch)
                    .font(.caption)

                    if activity.capturesTitles {
                        HStack(spacing: 10) {
                            Image(systemName: activity.accessibilityGranted ? "checkmark.seal.fill" : "lock.shield")
                                .foregroundStyle(activity.accessibilityGranted ? Color(hex: "#2C8158") : .secondary)
                            Text(activity.accessibilityGranted ? "窗口标题权限已允许。" : "读取窗口标题需要辅助功能权限。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(activity.accessibilityGranted ? "刷新" : "打开权限") { activity.requestAccessibility() }
                                .buttonStyle(.plain)
                                .smallAction()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 1280)
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

    private var storageCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 20) {
                Text("存储状态").font(.headline)

                HStack(spacing: 12) {
                    Image(systemName: store.isEncrypted ? "lock.shield.fill" : "lock.open")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(store.isEncrypted ? Color(hex: "#2C8158") : .secondary)
                        .frame(width: 32, height: 32)
                        .background(store.isEncrypted ? Color(hex: "#D9F2E3") : Color.chip, in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.isEncrypted ? "已加密保护" : "等待首次保存")
                            .font(.system(size: 13, weight: .semibold))
                        Text(store.stateFileSummary)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                row("修改天数", "\(store.localChangeCount) 天")
                row("快记条数", "\(store.quickCaptures.values.reduce(0) { $0 + $1.count }) 条")
                row("原始快照", "\(store.entries.count) 条")
                Toggle("自动整理", isOn: Binding(get: { !store.autoDraftPaused }, set: { store.setAutoDraftPaused(!$0) }))
                    .font(.caption)
                row("评分规则", "本机加权计算")
                row("状态解读", "本机关键词规则")

                Button {
                    revealStateFolder()
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                .buttonStyle(.plain)
                .smallAction()
            }
        }
    }

    private var controlCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 20) {
                Text("数据控制").font(.headline)

                Toggle("启动和应用切换时上锁", isOn: $appLockEnabled)
                    .toggleStyle(.switch)
                    .font(.caption)

                Text("应用锁会使用这台 Mac 的密码或生物识别；钥匙仍留在本机。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button {
                    exportBackup()
                } label: {
                    Label("导出加密备份", systemImage: "externaldrive.badge.timemachine")
                }
                .buttonStyle(.plain)
                .primaryCTA()

                Text("加密备份包含日记、修改、快记、实时连接设置、原始快照和 macOS 实时片段，适合迁移或长期保存。")
                    .font(.caption)
                    .lineSpacing(5)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        importBackup()
                    } label: {
                        Label("恢复备份", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                    .smallAction(dark: true)

                    Button {
                        exportData()
                    } label: {
                        Label("导出可读 JSON", systemImage: "doc.text")
                    }
                    .buttonStyle(.plain)
                    .smallAction()
                }

                Text("可读 JSON 未加密，只包含当天日记快照和修改，适合选择性查看；请只发送给自己。")
                    .font(.caption2)
                    .lineSpacing(4)
                    .foregroundStyle(.secondary)

                Divider()

                Button {
                    showsClearConfirmation = true
                } label: {
                    Label("清除本地修改", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .smallAction()

                Text("只清除 macOS 端改写和新增日期，不会删除原始数据。")
                    .font(.caption)
                    .lineSpacing(5)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("状态与权限", systemImage: "checkmark.seal")
                        .font(.headline)
                    Spacer()
                    StatusBadge(
                        healthSummary,
                        tone: healthSummary == "状态良好" ? .positive : healthSummary == "基本可用" ? .attention : .neutral
                    )
                }

                if diagnoses.isEmpty {
                    Label("数据连接体检：数据正常，字段和本地状态都可用。", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(Color(hex: "#2C8158"))
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(diagnoses, id: \.self) { item in
                            Label(item, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                EqualWidthRow(spacing: 14) {
                    rule("本地优先", "评分、筛选和图表本机完成；AI 只在你点生成时请求。")
                    rule("密钥保护", "API Key 保存在 macOS 钥匙串。")
                    rule("最小请求", "只发送所选日期/范围的日记摘要；窗口标题需单独允许。")
                }
            }
        }
        .frame(maxWidth: 1280)
    }

    private var diagnoses: [String] {
        var items: [String] = []

        if !ingestion.enabled {
            items.append("定时数据采集已关闭，健康/评分数据不会自动更新。")
        } else if ingestion.dailyRecord == nil {
            items.append("还没有完成每日混合数据采集。")
        } else if let error = ingestion.lastError {
            items.append("数据采集失败：\(error)")
        }
        if store.externalSourceURL == nil {
            items.append("尚未连接 data.json，主页和足迹暂时使用内置快照。")
        }
        if let error = store.externalSourceError {
            items.append("数据文件读取失败：\(error)")
        }
        if store.entries.count < 7 {
            items.append("日记数据不足 7 天，趋势类内容会比较有限。")
        }

        let sorted = store.entries.sorted { $0.date < $1.date }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let first = sorted.first, let last = sorted.last {
            let lastDate = last.entryDate ?? Date()
            var current = first.entryDate ?? Date()
            var missing = 0
            while current <= lastDate {
                let key = formatter.string(from: current)
                if !store.entries.contains(where: { $0.date == key }) { missing += 1 }
                current = Calendar.current.date(byAdding: .day, value: 1, to: current) ?? current.addingTimeInterval(86400)
            }
            if missing > 0 {
                items.append("连接范围内有 \(missing) 天缺少日记数据。")
            }
        }

        let missingHealth = sorted.filter { $0.health == nil }.count
        if missingHealth > 0 {
            items.append("\(missingHealth) 天缺少运动数据；实时足迹会补充分布，但补不了每日步数。")
        }
        if activity.capturesTitles && !activity.accessibilityGranted {
            items.append("窗口标题权限未允许；足迹只能记录应用名，不能记录窗口标题。")
        }
        if ai.isEnabled && !ai.isConfigured {
            items.append("AI 分析模式已开启，但还没有可用的模型连接。")
        }
        return items
    }

    private func rule(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "checkmark.seal")
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.caption)
                .lineSpacing(5)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var healthSummary: String {
        let scores = [
            ingestion.enabled ? 1 : 0,
            ingestion.dailyRecord != nil ? 1 : 0,
            store.externalSourceURL != nil ? 1 : 0,
            store.entries.count >= 7 ? 1 : 0,
            activity.isTracking ? 1 : 0,
            activity.capturesTitles ? (activity.accessibilityGranted ? 1 : 0) : 1,
            store.isEncrypted || !store.hasLocalChanges ? 1 : 0,
            ai.analysisReady ? 1 : 0
        ]
        let ready = scores.reduce(0, +)
        return ready >= 8 ? "状态良好" : ready >= 5 ? "基本可用" : "需要设置"
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.weight(.semibold))
        }
    }

    private func exportData() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "RiverDiary-\(DiaryEntry.dateFormatter.string(from: Date())).json"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            exportMessage = nil
            return
        }

        do {
            try store.exportCurrentData(to: url)
            exportMessage = "已导出到 \(url.lastPathComponent)"
        } catch {
            exportMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "RiverDiaryBackup-\(DiaryEntry.dateFormatter.string(from: Date())).json"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try store.exportFullBackup(to: url, activitySessions: activity.sessions)
            exportMessage = "已创建加密备份：\(url.lastPathComponent)"
        } catch {
            exportMessage = "备份失败：\(error.localizedDescription)"
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "选择 River Diary 生成的加密备份"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingRestoreURL = url
        showsRestoreConfirmation = true
    }

    private func restoreBackup() {
        guard let url = pendingRestoreURL else { return }
        do {
            try store.restoreFullBackup(from: url) { try activity.restoreBackup($0) }
            exportMessage = "备份已恢复。"
        } catch {
            exportMessage = "恢复失败：\(error.localizedDescription)"
        }
        pendingRestoreURL = nil
    }

    private func revealStateFolder() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RiverDiaryMac", isDirectory: true)

        guard let directory else { return }
        NSWorkspace.shared.open(directory)
    }

    private func profilesContain(_ id: String) -> Bool {
        ai.profiles.contains { $0.id == id }
    }

    private var aiCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("连接模型 API", systemImage: "sparkles.rectangle.stack")
                        .font(.headline)
                    Spacer()
                    StatusBadge(ai.isConfigured ? "已连接" : "未连接", tone: ai.isConfigured ? .positive : .neutral)
                }

                Text("支持 OpenAI 兼容、DeepSeek、Moonshot、OpenRouter、阿里云百炼、智谱、xAI、Groq、Mistral、SiliconFlow、Ollama 和 LM Studio。可以保存多个方案，随时切换。")
                    .font(.caption)
                    .lineSpacing(6)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Picker("模型方案", selection: Binding(
                            get: { ai.activeProfile?.id ?? "" },
                            set: { newValue in
                                if profilesContain(newValue) {
                                    ai.selectedProfileID = newValue
                                }
                            }
                        )) {
                            ForEach(ai.profiles) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 220)

                        Button("新增方案") { ai.addProfile() }
                            .buttonStyle(.plain)
                            .smallAction()
                        Button("复制") { ai.duplicateProfile() }
                            .buttonStyle(.plain)
                            .smallAction()
                        Button("删除") { ai.removeProfile() }
                            .buttonStyle(.plain)
                            .smallAction()
                            .disabled(ai.profiles.count <= 1)
                    }

                    HStack(spacing: 10) {
                        TextField("方案名称", text: Binding(
                            get: { ai.profileName },
                            set: { ai.profileName = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                        Picker("服务商", selection: $ai.provider) {
                            ForEach(AIProvider.allCases) { provider in
                                Text(provider.label).tag(provider)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 190)

                        Toggle("发送窗口标题", isOn: $ai.includeTitles)
                            .toggleStyle(.switch)
                            .font(.caption)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("API 地址")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("https://api.example.com/v1/chat/completions", text: $ai.endpoint)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    }

                    if ai.providerRequiresAPIKey {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("API Key")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                SecureField(ai.hasAPIKey ? "已保存到钥匙串" : "粘贴 API Key", text: $ai.apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                Button("保存 Key") { ai.saveAPIKey() }
                                    .buttonStyle(.plain)
                                    .smallAction()
                                if ai.hasAPIKey {
                                    Button("移除") { ai.deleteAPIKey() }
                                        .buttonStyle(.plain)
                                        .smallAction()
                                }
                            }
                        }
                    } else {
                        Label("本地模型不需要 API Key。", systemImage: "desktopcomputer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("模型名称")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if ai.availableModels.isEmpty {
                            TextField("例如 gpt-4o-mini / deepseek-chat / qwen-plus", text: $ai.model)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                        } else {
                            Picker("可用模型", selection: Binding(
                                get: { ai.availableModels.contains(ai.model) ? ai.model : (ai.model.isEmpty ? "" : "__manual__") },
                                set: { newValue in
                                    if newValue != "__manual__" {
                                        ai.model = newValue
                                    }
                                }
                            )) {
                                if ai.availableModels.contains(ai.model) {
                                    Text(ai.model).tag(ai.model)
                                } else {
                                    Text(ai.model.isEmpty ? "选择可用模型" : "手动输入：\(ai.model)").tag("__manual__")
                                }
                                ForEach(ai.availableModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            TextField("手动输入模型名称", text: $ai.model)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                        }

                        HStack(spacing: 8) {
                            Button {
                                Task { await ai.fetchAvailableModels() }
                            } label: {
                                if ai.isLoadingModels {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.mini)
                                        Text("获取中…")
                                    }
                                } else {
                                    Text("获取可用模型")
                                }
                            }
                            .buttonStyle(.plain)
                            .smallAction(dark: true)
                            .disabled(ai.isLoadingModels)

                            Button {
                                Task { await ai.testConnection() }
                            } label: {
                                if ai.isLoading {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.mini)
                                        Text("测试中…")
                                    }
                                } else {
                                    Text("测试连接")
                                }
                            }
                            .buttonStyle(.plain)
                            .smallAction(dark: ai.canTestConnection)
                            .disabled(!ai.canTestConnection || ai.isLoading)

                            Spacer()

                            Text(ai.isConfigured ? "已可使用" : ai.canTestConnection ? "Key 待保存，测试时会自动保存" : ai.providerRequiresAPIKey ? "还需要 API Key、地址和模型" : "还需要地址和模型")
                                .font(.caption)
                                .foregroundStyle(ai.isConfigured ? Color(hex: "#2C8158") : .secondary)
                        }

                        if let message = ai.modelMessage {
                            Label(message, systemImage: message.contains("失败") ? "exclamationmark.triangle" : "list.bullet")
                                .font(.caption)
                                .foregroundStyle(message.contains("失败") ? .red : Color(hex: "#2C8158"))
                        }
                    }

                    HStack(spacing: 8) {
                        Button("清除回答") { ai.resetAnswer() }
                            .buttonStyle(.plain)
                            .smallAction()
                        Spacer()
                        if let summary = ai.requestSummary {
                            Text("上次请求：\(summary)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let message = ai.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .frame(maxWidth: 1280)
    }
}
