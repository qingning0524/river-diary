import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PrivacyBackupSettingsView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore
    @State private var showsClearConfirmation = false
    @State private var showsRestoreConfirmation = false
    @State private var pendingRestoreURL: URL?
    @AppStorage("privacy.appLockEnabled") private var appLockEnabled = false
    @EnvironmentObject private var feedbackCenter: FeedbackCenter

    var body: some View {
        SettingsPage {
            storageCard
            controlCard
            statusCard
        }
        .confirmationDialog("要清除所有本地日记修改吗？", isPresented: $showsClearConfirmation, titleVisibility: .visible) {
            Button("清除修改", role: .destructive) { store.clearLocalJournal() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清除你在 Mac 上写过的内容和先搁下的状态；随手记和原始日子不会受影响。")
        }
        .confirmationDialog("要用这个备份替换当前数据吗？", isPresented: $showsRestoreConfirmation, titleVisibility: .visible) {
            Button("恢复备份", role: .destructive) { restoreBackup() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("恢复前会校验快照并加密保存当前数据的恢复点。运行中失败会回滚；若应用意外退出，下次启动会先尝试恢复旧数据，成功前不会打开数据页面。")
        }
    }

    private var storageCard: some View {
        SettingsGroup(title: "存储状态", detail: store.stateFileSummary) {
            RiverPanel {
                RiverPanelRow(
                    title: store.isEncrypted ? "已加密保护" : "等待首次保存",
                    detail: store.isEncrypted
                        ? "journal.state 使用 AES-GCM；兼容库与 V2 事实库使用 SQLCipher。"
                        : "完成第一次保存后会自动加密。",
                    systemImage: store.isEncrypted ? "lock.shield.fill" : "lock.open"
                ) {
                    StatusBadge(store.isEncrypted ? "已加密" : "待保存", tone: store.isEncrypted ? .positive : .neutral)
                }

                RiverValueRow(title: "修改天数", value: "\(store.localChangeCount) 天")
                RiverValueRow(title: "快记条数", value: "\(store.quickCaptures.values.reduce(0) { $0 + $1.count }) 条")
                RiverValueRow(title: "原始快照", value: "\(store.entries.count) 条")
                RiverValueRow(title: "评分规则", value: "本机加权计算")
                RiverValueRow(title: "状态解读", value: "本机关键词规则")

                RiverPanelRow(title: "自动整理", detail: "停止输入后自动保存并加密", showsDivider: false) {
                    Toggle("自动整理", isOn: Binding(
                        get: { !store.autoDraftPaused },
                        set: { store.setAutoDraftPaused(!$0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    SettingsFootnote(text: "数据库密钥由本机状态密钥派生，启动不需要输入密码。密钥只保存在这台 Mac 的当前用户目录；若密钥文件丢失，数据库无法解密，同一账户下运行的其他进程仍可读取它。")
                    HStack(spacing: AppSpacing.sm) {
                        Button {
                            revealStateFolder()
                        } label: {
                            Label("在 Finder 中显示", systemImage: "folder")
                        }
                        .buttonStyle(.plain)
                        .smallAction()

                        Button {
                            if let url = Bundle.module.url(forResource: "ThirdPartyNotices", withExtension: "md") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("查看第三方许可", systemImage: "doc.text")
                        }
                        .buttonStyle(.plain)
                        .smallAction()
                        Spacer()
                    }
                }
                .padding(.top, AppSpacing.md)
            }
        }
    }

    private var controlCard: some View {
        SettingsGroup(title: "数据控制", detail: "备份、恢复与清除都只在本机完成。") {
            RiverPanel {
                RiverPanelRow(title: "启动和应用切换时上锁", detail: "使用这台 Mac 的密码或生物识别") {
                    Toggle("启动和应用切换时上锁", isOn: $appLockEnabled)
                        .toggleStyle(.switch)
                        .tint(AppTheme.accent)
                        .labelsHidden()
                }

                RiverPanelRow(title: "导出加密备份", detail: "包含日记、修改、快记与两个事实库的加密快照") {
                    HStack(spacing: AppSpacing.sm) {
                        Button { exportBackup() } label: {
                            Label("导出", systemImage: "externaldrive.badge.timemachine")
                        }
                        .buttonStyle(.plain)
                        .smallAction(dark: true)
                    }
                }

                RiverPanelRow(title: "恢复备份", detail: "要求保留同一加密密钥；跨设备密钥恢复尚未实现") {
                    HStack(spacing: AppSpacing.sm) {
                        Button { importBackup() } label: {
                            Label("恢复", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.plain)
                        .smallAction()
                        Button { exportData() } label: {
                            Label("可读 JSON", systemImage: "doc.text")
                        }
                        .buttonStyle(.plain)
                        .smallAction()
                    }
                }

                RiverPanelRow(
                    title: "清除本地修改",
                    detail: "只清除 macOS 端改写和新增日期，不会删除原始数据。",
                    showsDivider: false
                ) {
                    Button {
                        showsClearConfirmation = true
                    } label: {
                        Label("清除", systemImage: "trash")
                    }
                    .buttonStyle(.plain)
                    .smallAction()
                }
            }
        }
    }

    private var statusCard: some View {
        SettingsGroup(title: "状态与权限", detail: "本机数据的体检结果。") {
            RiverPanel {
                RiverPanelRow(title: "数据连接体检", detail: diagnoses.isEmpty ? "数据正常，字段和本地状态都可用。" : "有 \(diagnoses.count) 项需要留意") {
                    StatusBadge(
                        healthSummary,
                        tone: healthSummary == "状态良好" ? .positive : healthSummary == "基本可用" ? .attention : .neutral
                    )
                }

                if !diagnoses.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        ForEach(diagnoses, id: \.self) { item in
                            HStack(alignment: .top, spacing: AppSpacing.sm) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(AppTheme.warning)
                                Text(item)
                                    .font(AppTypography.secondary())
                                    .foregroundStyle(Color.secondaryInk)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppSpacing.sm)
                }

                EqualWidthRow(spacing: AppSpacing.lg) {
                    privacyRule("本地优先", "评分、筛选和图表本机完成；AI 仅在手动生成或已开启的定时分析时请求。")
                    privacyRule("密钥保护", "API Key 保存在本机加密文件，并限制为当前用户可读。")
                    privacyRule("发送范围", "请求发送给当前模型服务商：所选范围的日记、评分、已选来源活动和快记；人工标注与每日目标仅在你手动请求相关 AI 回答时作为候选。窗口标题由单独开关控制。")
                }
                .padding(.top, AppSpacing.md)
            }
        }
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
        if !ai.hasVerifiedConnection {
            items.append("AI 分析还没有完成可用的模型连接验证。")
        }
        return items
    }

    private func privacyRule(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Label(title, systemImage: "checkmark.seal")
                .font(AppTypography.rowTitle())
                .foregroundStyle(Color.ink)
            Text(detail)
                .font(AppTypography.metadata())
                .lineSpacing(4)
                .foregroundStyle(Color.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
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

    private func exportData() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "RiverDiary-\(DiaryEntry.dateFormatter.string(from: Date())).json"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try store.exportCurrentData(to: url)
            report("已导出到 \(url.lastPathComponent)", kind: .success)
        } catch {
            report("导出失败：\(UserFacingError.message(for: error))", kind: .error)
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.nameFieldStringValue = "RiverDiaryBackup-\(DiaryEntry.dateFormatter.string(from: Date())).riverbackup"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let legacySnapshot = try AppDatabase.shared.encryptedSnapshot()
            let v2Snapshot = try activity.encryptedV2Snapshot()
            try store.exportFullBackup(
                to: url,
                activitySessions: activity.allSessionsIncludingActive(),
                legacyDatabaseSnapshot: legacySnapshot,
                v2DatabaseSnapshot: v2Snapshot
            )
            report("已创建加密备份：\(url.lastPathComponent)", kind: .success)
        } catch {
            report("备份失败：\(UserFacingError.message(for: error))", kind: .error)
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.message = "选择 River Diary 生成的加密备份"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingRestoreURL = url
        showsRestoreConfirmation = true
    }

    private func restoreBackup() {
        guard let url = pendingRestoreURL else { return }
        do {
            let previousActivity = activity.allSessionsIncludingActive()
            let previousLegacySnapshot = try AppDatabase.shared.encryptedSnapshot()
            let previousV2Snapshot = try activity.encryptedV2Snapshot()
            try store.restoreFullBackup(
                from: url,
                restoreActivity: { try activity.restoreBackup($0) },
                validateDatabaseSnapshots: { legacySnapshot, v2Snapshot in
                    if let legacySnapshot { try AppDatabase.shared.validateEncryptedSnapshot(legacySnapshot) }
                    if let v2Snapshot { try activity.validateV2Snapshot(v2Snapshot) }
                },
                restoreDatabaseSnapshots: { legacySnapshot, v2Snapshot in
                    if let legacySnapshot { try AppDatabase.shared.restoreEncryptedSnapshot(legacySnapshot) }
                    if let v2Snapshot { try activity.restoreV2Snapshot(v2Snapshot) }
                },
                rollbackExternalData: {
                    var failures: [String] = []
                    do {
                        try AppDatabase.shared.restoreEncryptedSnapshot(previousLegacySnapshot)
                    } catch {
                        failures.append("兼容数据库：\(UserFacingError.message(for: error))")
                    }
                    do {
                        try activity.restoreV2Snapshot(previousV2Snapshot)
                    } catch {
                        failures.append("V2 事实库：\(UserFacingError.message(for: error))")
                    }
                    do {
                        try activity.restoreBackup(previousActivity)
                    } catch {
                        failures.append("实时足迹：\(UserFacingError.message(for: error))")
                    }
                    guard failures.isEmpty else {
                        throw NSError(
                            domain: "RiverDiaryMac",
                            code: 12,
                            userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "；")]
                        )
                    }
                },
                recoverySnapshot: RestoreRecoverySnapshot(
                    activitySessions: previousActivity,
                    legacyDatabaseSnapshot: previousLegacySnapshot,
                    v2DatabaseSnapshot: previousV2Snapshot,
                    trackingEnabled: activity.isTracking
                )
            )
            report("备份已恢复。", kind: .success)
        } catch {
            report("恢复失败：\(UserFacingError.message(for: error))", kind: .error)
        }
        pendingRestoreURL = nil
    }

    private func revealStateFolder() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RiverDiaryMac", isDirectory: true)

        guard let directory else { return }
        NSWorkspace.shared.open(directory)
    }

    private func report(_ message: String, kind: FeedbackKind) {
        feedbackCenter.show(message, kind: kind)
    }

}
