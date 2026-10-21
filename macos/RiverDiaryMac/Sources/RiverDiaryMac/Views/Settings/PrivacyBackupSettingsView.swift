import AppKit
import SwiftUI
import RiverDiaryCore
import UniformTypeIdentifiers

struct PrivacyBackupSettingsView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore
    @StateObject private var sync: SyncSettingsStore
    @StateObject private var eveningReminder = EveningReminderStore()
    @State private var syncKeyInput = ""
    @State private var showsSyncKey = false
    @State private var showsClearConfirmation = false
    @State private var showsRestoreConfirmation = false
    @State private var pendingRestoreURL: URL?
    @AppStorage("privacy.appLockEnabled") private var appLockEnabled = false
    @AppStorage("backup.lastExportAt") private var lastExportAt: Double = 0
    @State private var inspectionResult: String?
    @AppStorage("river.developerMode.enabled") private var developerModeEnabled = false
    @State private var diagnosticsDocument: RiverMacDiagnosticsDocument?
    @State private var showsDiagnosticsExport = false
    @EnvironmentObject private var feedbackCenter: FeedbackCenter

    init(store: DiaryStore, activity: ActivityStore, ai: AIAssistantStore, ingestion: DataIngestionStore) {
        self.store = store
        self.activity = activity
        self.ai = ai
        self.ingestion = ingestion
        _sync = StateObject(wrappedValue: activity.syncSettingsStore)
    }

    var body: some View {
        SettingsPage {
            storageCard
            syncCard
            controlCard
            statusCard
            developerModeCard
            if developerModeEnabled { diagnosticsCard }
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
        .fileExporter(
            isPresented: $showsDiagnosticsExport,
            document: diagnosticsDocument,
            contentType: .json,
            defaultFilename: "RiverDiary-Mac-Diagnostics.json"
        ) { result in
            switch result {
            case .success(let url): sync.setDiagnosticActionMessage("诊断报告已导出到 \(url.lastPathComponent)。")
            case .failure(let error): sync.setDiagnosticActionMessage("诊断报告导出失败：\(error.localizedDescription)")
            }
        }
    }

    private var developerModeCard: some View {
        SettingsGroup(title: "开发者模式", detail: "仅用于诊断和验收；开启后会显示 Developer Diagnostics 操作。") {
            RiverPanel {
                RiverPanelRow(title: "显示 Developer Diagnostics", detail: "包括本机计数、同步状态和诊断动作。") {
                    Toggle("Developer Diagnostics", isOn: $developerModeEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
    }

    private var diagnosticsCard: some View {
        let database = activity.replicationDatabase()
        let events = database.allRawEvents()
        let frontier = try? database.ownedFrontier()
        let canonical = database.canonicalArtifactRevisions()
        let sessionCount = SessionBuilder.build(events.compactMap { $0.replica() }).count
        return SettingsGroup(title: "开发者诊断", detail: "开发者模式开启时显示。报告只包含计数、状态和摘要，不包含事件正文、坐标或密钥。") {
            RiverPanel {
                RiverValueRow(title: "设备 ID", value: database.localDeviceIdentifier()?.rawValue ?? "不可用")
                RiverValueRow(title: "数据库版本", value: "\(database.databaseSchemaVersion)")
                RiverValueRow(title: "事件 / 会话 / 地点", value: "\(database.countRows(in: .rawEvents)) / \(sessionCount) / \(database.places().count)")
                RiverValueRow(title: "状态操作", value: "\(database.countRows(in: .stateOperations))")
                RiverValueRow(title: "产物 / 正本 / 过期", value: "\(database.countRows(in: .artifacts)) / \(canonical.count) / \(database.staleArtifactRevisionCount())")
                let pendingHabitCount = database.habitCardRows().filter { $0.status == "bundled" || $0.status == "shown" }.count
                let pendingMemoryCount = database.memories().filter { database.memoryConfirmation(for: $0.id)?.confirmed != true }.count
                let pendingSharedCount = database.sharedUserRecords().filter {
                    $0.kind == .pendingConfirmation && $0.status == "pending"
                }.count
                RiverValueRow(title: "待确认项", value: "通用 \(pendingSharedCount) · 习惯卡 \(pendingHabitCount) · 记忆 \(pendingMemoryCount)")
                RiverValueRow(title: "已导入对象", value: "\(database.countRows(in: .syncImports))")
                RiverValueRow(title: "同步批次（导出 / 导入）", value: "E \(sync.lastReport?.exportedEventBatches ?? 0)/\(sync.lastReport?.importedEventBatches ?? 0) · O \(sync.lastReport?.exportedOperationBatches ?? 0)/\(sync.lastReport?.importedOperationBatches ?? 0) · A \(sync.lastReport?.exportedArtifactRevisions ?? 0)/\(sync.lastReport?.importedArtifactRevisions ?? 0)")
                RiverValueRow(title: "事件 / 操作水位", value: "\(frontier?.events ?? 0) / \(frontier?.operations ?? 0)")
                RiverValueRow(title: "选定的 iCloud 目录", value: sync.folderName ?? "未选择")
                RiverValueRow(title: "目录授权", value: sync.folderName == nil ? "未配置" : (sync.lastError == nil ? "已保存；同步时重验" : "需要检查授权"))
                RiverValueRow(title: "局域网同步", value: sync.isLANReplicating ? sync.lanSyncStatus : "未启用")
                RiverValueRow(title: "最近导出 / 导入时间", value: "\(sync.lastSuccessfulExportAt?.formatted(date: .abbreviated, time: .shortened) ?? "—") / \(sync.lastImportAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")")
                RiverValueRow(title: "最近核对 / 校验", value: "\(sync.lastRunAt?.formatted(date: .abbreviated, time: .shortened) ?? "—") / \(sync.lastVerifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")")
                RiverValueRow(title: "正本摘要", value: (try? database.canonicalStateDigest()) ?? "不可用")
                RiverValueRow(title: "缺失序号", value: sync.lastReport.map { report in
                    report.missingSequenceGaps.isEmpty
                        ? "无"
                        : report.missingSequenceGaps.map { "\($0.deviceID.rawValue)/\($0.stream) \($0.first)-\($0.last)" }.joined(separator: ", ")
                } ?? "最近一次扫描未运行")
                RiverValueRow(title: "完整性问题", value: sync.lastReport?.integrityFailures.isEmpty == false ? sync.lastReport!.integrityFailures.joined(separator: "\n") : "无")
                RiverValueRow(title: "位置授权", value: sync.locationAuthorizationProvider?() ?? "未接入")
                RiverValueRow(title: "最近位置事件", value: events.filter { $0.source == .location }.max { $0.timestamp < $1.timestamp }?.timestamp.formatted(date: .abbreviated, time: .shortened) ?? "—")
                RiverValueRow(title: "最近逆地理编码", value: events.filter { $0.source == .location && $0.payload.mapProvider != nil }.max { $0.recordedAt < $1.recordedAt }?.recordedAt.formatted(date: .abbreviated, time: .shortened) ?? "—")
                RiverValueRow(title: "地图候选记录", value: "\(events.filter { $0.source == .location && $0.payload.mapProvider != nil }.count)")
                RiverValueRow(title: "最近快捷指令记录", value: events.filter { $0.persistedSource == "shortcuts" }.max { $0.recordedAt < $1.recordedAt }?.recordedAt.formatted(date: .abbreviated, time: .shortened) ?? "—")
                let latestJob = database.latestAnalysisJob().map { "\($0.status.rawValue) · \($0.logicalKey) · attempt \($0.attempt)" } ?? "暂无已记录任务"
                RiverValueRow(title: "AI 任务", value: [latestJob, ai.recoveredAnalysisStatus].compactMap { $0 }.joined(separator: " · "))

                HStack(spacing: AppSpacing.sm) {
                    Button("写入测试事件") {
                        sync.setDiagnosticActionMessage(activity.generateDiagnosticTestEvent() ? "已写入一条本机测试事件。" : "测试事件写入失败。")
                    }.buttonStyle(.plain).smallAction()
                    Button("强制导出事件批次") { sync.runDiagnosticSyncAction("强制导出事件批次") }
                        .buttonStyle(.plain).smallAction()
                    Button("强制导出状态操作") { sync.runDiagnosticSyncAction("强制导出状态操作") }
                        .buttonStyle(.plain).smallAction()
                    Button("扫描 / 导入 / 核对 / 校验") { sync.runDiagnosticSyncAction("扫描 / 导入 / 核对 / 校验") }
                        .buttonStyle(.plain).smallAction()
                    Spacer()
                }
                HStack(spacing: AppSpacing.sm) {
                    Button("重建会话 / 地点 / 时间线") { sync.rebuildDiagnosticProjections(activity: activity) }
                        .buttonStyle(.plain).smallAction()
                    Button("作废 AI 产物") { sync.invalidateArtifactsForDiagnostics() }
                        .buttonStyle(.plain).smallAction()
                    Button("重算正本状态") { sync.runDiagnosticSyncAction("重算正本状态") }
                        .buttonStyle(.plain).smallAction()
                    Button("导出诊断报告") {
                        guard let data = sync.makeDiagnosticsReport(activity: activity) else {
                            sync.setDiagnosticActionMessage("无法读取诊断快照。")
                            return
                        }
                        diagnosticsDocument = RiverMacDiagnosticsDocument(data: data)
                        showsDiagnosticsExport = true
                    }
                    .buttonStyle(.plain).smallAction(dark: true)
                    Spacer()
                }
                if let message = sync.diagnosticActionMessage {
                    SettingsFootnote(text: message)
                }
                if let failures = sync.lastReport?.integrityFailures, !failures.isEmpty {
                    ForEach(failures.indices, id: \.self) { index in
                        Text(failures[index]).font(AppTypography.micro()).foregroundStyle(Color.red).textSelection(.enabled)
                    }
                }
                SettingsFootnote(text: "同步诊断按钮都会运行完整管线：发布本机 Event、Operation 和 Artifact，扫描并导入远端对象，重建派生状态后检查前沿、摘要和文件完整性。")
            }
        }
    }

    private var syncCard: some View {
        SettingsGroup(title: "跨设备加密同步", detail: "通过 iCloud Drive 复制不可变对象；SQLite 数据库留在各设备本机。") {
            RiverPanel {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    RiverPanelRow(
                        title: sync.status,
                        detail: sync.folderName.map { "共享文件夹 · \($0)" } ?? "尚未选择共享文件夹",
                        systemImage: sync.isSyncing ? "arrow.triangle.2.circlepath.icloud" : "lock.icloud"
                    ) {
                        StatusBadge(sync.isSyncing ? "同步中" : (sync.isVerified ? "已核对" : "待核对"),
                                    tone: sync.isSyncing ? .neutral : (sync.isVerified ? .positive : .neutral))
                    }

                    HStack(spacing: AppSpacing.sm) {
                        Button("选择 iCloud Drive 文件夹", action: sync.chooseFolder)
                            .buttonStyle(.plain)
                            .smallAction()
                        Button(sync.isSyncing ? "正在同步…" : "立即同步并核对", action: sync.synchronize)
                            .buttonStyle(.plain)
                            .smallAction()
                            .disabled(sync.isSyncing || sync.folderName == nil)
                        Spacer()
                    }

                    Text("换机或重装前必须保存这串恢复码。只存在本机钥匙串里的密钥会随设备一起丢失；没有它，加密备份和同步对象都无法解密。")
                        .font(AppTypography.micro())
                        .foregroundStyle(AppTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: AppSpacing.sm) {
                        Button(showsSyncKey ? "隐藏恢复码" : "显示或创建恢复码") {
                            if !showsSyncKey { sync.revealOrCreateKey() }
                            showsSyncKey.toggle()
                        }
                        .buttonStyle(.plain)
                        .smallAction()
                        if let code = sync.transferCode, showsSyncKey {
                            Button("复制恢复码") { NSPasteboard.general.setString(code, forType: .string) }
                                .buttonStyle(.plain)
                                .smallAction()
                            Button("导出恢复说明…") { exportRecoveryKit() }
                                .buttonStyle(.plain)
                                .smallAction()
                        }
                    }
                    if let code = sync.transferCode, showsSyncKey {
                        Text(code)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !sync.devices.isEmpty {
                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                            Text("已登记设备")
                                .font(AppTypography.label())
                            ForEach(sync.devices) { device in
                                HStack(spacing: AppSpacing.sm) {
                                    Image(systemName: device.lifecycle == .active ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                                        .foregroundStyle(device.lifecycle == .active ? AppTheme.accent : Color.secondaryInk)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.displayName)
                                            .font(AppTypography.secondary())
                                        Text("\(device.platform) · \(device.lifecycle == .active ? "参与核对" : "已退役")")
                                            .font(AppTypography.micro())
                                            .foregroundStyle(Color.secondaryInk)
                                    }
                                    Spacer()
                                    if device.lifecycle == .active, device.id != sync.localDeviceID {
                                        Button("退役") { sync.retireDevice(device.id) }
                                            .buttonStyle(.plain)
                                            .smallAction()
                                    }
                                }
                            }
                        }
                    }
                    if sync.unresolvedDecisionConflicts > 0 {
                        Text("有 \(sync.unresolvedDecisionConflicts) 项不同设备对同一用户状态做了并发修改；当前显示采用逻辑时钟较新的决定，两个版本都已保留。")
                            .font(AppTypography.micro())
                            .foregroundStyle(AppTheme.warning)
                    }

                    if !sync.places.isEmpty {
                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                            Text("地点候选与已确认地点")
                                .font(AppTypography.label())
                            ForEach(sync.places) { place in
                                PlaceDecisionMacRow(place: place) { name, type in
                                    sync.savePlaceDecision(place, name: name, semanticType: type)
                                }
                            }
                        }
                    }

                    RiverPanelRow(title: "附近设备快速复制", detail: sync.lanSyncStatus) {
                        Toggle("启用局域网复制", isOn: Binding(
                            get: { sync.isLANReplicating },
                            set: { sync.setLANReplicationEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }

                    HStack(spacing: AppSpacing.sm) {
                        SecureField("从 iPhone 粘贴同步密钥", text: $syncKeyInput)
                            .textFieldStyle(.roundedBorder)
                        Button("导入") {
                            sync.importKey(syncKeyInput)
                            syncKeyInput = ""
                        }
                        .buttonStyle(.plain)
                        .smallAction()
                        .disabled(syncKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let error = sync.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    SettingsFootnote(text: "在 iPhone 和 Mac 上选择同一个文件夹，并导入同一密钥。密钥只保存在各自的钥匙串中；同步文件以 AES-GCM 加密并带 SHA-256 完整性校验。")
                }
            }
        }
    }

    private var storageCard: some View {
        SettingsGroup(title: "信任与存储", detail: "本机加密、采集时间与数据范围。") {
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

                RiverValueRow(title: "最近采集", value: lastCaptureText)
                RiverValueRow(title: "实时片段", value: "\(activity.sessions.count) 段 · 近 365 天")
                RiverValueRow(title: "项目数据源", value: store.externalSourceURL == nil ? "内置快照" : "已连接")
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

    private var lastCaptureText: String {
        if let last = ingestion.lastIngestedAt {
            let prefix = Calendar.current.isDateInToday(last) ? "今天 " : ""
            return "\(prefix)\(last.formatted(date: .omitted, time: .shortened))"
        }
        return ingestion.enabled ? "等待下一次采集" : "未启用"
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

                // 与 iPhone 端同一时刻、同一文案的晚间提醒；此前 Mac 完全没有通知能力。
                RiverPanelRow(
                    title: "晚间提醒（21:30）",
                    detail: eveningReminder.message ?? "每天晚上温和地提醒一句：今天有什么想记下的。"
                ) {
                    Toggle("晚间提醒", isOn: Binding(
                        get: { eveningReminder.isEnabled },
                        set: { newValue in
                            Task { await eveningReminder.setEnabled(newValue) }
                        }
                    ))
                    .toggleStyle(.switch)
                    .tint(AppTheme.accent)
                    .labelsHidden()
                }

                if lastExportAt > 0 {
                    Text("上次加密备份：\(Date(timeIntervalSince1970: lastExportAt).formatted(date: .abbreviated, time: .shortened))")
                        .font(AppTypography.micro())
                        .foregroundStyle(Color.secondaryInk)
                }
                if let warning = backupAgeWarning {
                    Text(warning)
                        .font(AppTypography.micro())
                        .foregroundStyle(AppTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
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

                RiverPanelRow(title: "网页控制台副本", detail: "导出 river.memory-mirror 只读 JSON；在 user.flowriver.xyz 导入后只读查看。包含当前设备可读的日记与双端“设备上下文”，不含密钥、健康原库或完整浏览器 URL。") {
                    Button { exportReadableJSON(filenamePrefix: "RiverDiary-Web") } label: {
                        Label("导出 JSON", systemImage: "doc.text")
                    }
                    .buttonStyle(.plain)
                    .smallAction()
                    .accessibilityIdentifier("settings.webExport")
                }

                RiverPanelRow(title: "检查备份文件", detail: "只读校验恢复码、日记内容和两个事实库快照；不修改现有数据") {
                    Button { inspectBackup() } label: {
                        Label("检查", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.plain)
                    .smallAction()
                    .accessibilityIdentifier("settings.backup.inspect")
                }
                if let inspectionResult {
                    Text(inspectionResult)
                        .font(AppTypography.micro())
                        .foregroundStyle(inspectionResult.hasPrefix("备份有效") ? Color.green : AppTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                RiverPanelRow(title: "恢复备份", detail: "备份不含密钥；从仍有密钥的设备复制转移码，在此设备导入后恢复") {
                    HStack(spacing: AppSpacing.sm) {
                        Button { importBackup() } label: {
                            Label("恢复", systemImage: "square.and.arrow.down")
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

                RiverPanelRow(
                    title: "网络 AI 数据授权",
                    detail: ai.allowRemoteAnalysis
                        ? "已同意把所选的日记与活动资料发送给当前网络模型。"
                        : "默认关闭；开启后才会把个人数据发送给网络模型。Ollama / LM Studio 本机服务不受此项限制。",
                    systemImage: ai.allowRemoteAnalysis ? "network" : "network.slash",
                    showsDivider: false
                ) {
                    Toggle("允许发送", isOn: $ai.allowRemoteAnalysis)
                        .toggleStyle(.switch)
                        .labelsHidden()
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
                    privacyRule("本地优先", "评分、筛选和图表本机完成；网络模型仅在你明确开启上方授权后接收个人数据。")
                    privacyRule("密钥保护", "API Key 保存在本机加密文件，并限制为当前用户可读。")
                    privacyRule("发送范围", "授权开启后，分析仍遵守 AI 设置中的标题、浏览与地点开关；位置坐标不会发送。关闭授权后，网络分析会停在本机并说明原因。")
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
        // 用 Set 判断缺失：原来的 `entries.contains` 放在逐日循环里是 O(天数 × 条数)。
        let existingDates = Set(store.entries.map(\.date))
        if let first = sorted.first, let last = sorted.last {
            let lastDate = last.entryDate ?? Date()
            var current = first.entryDate ?? Date()
            var missing = 0
            while current <= lastDate {
                let key = DiaryEntry.dateFormatter.string(from: current)
                if !existingDates.contains(key) { missing += 1 }
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

    private func exportReadableJSON(filenamePrefix: String = "RiverDiary") {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(filenamePrefix)-\(DiaryEntry.dateFormatter.string(from: Date())).json"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try store.webMirrorData(contexts: ingestion.dayContextSnapshotsForWeb()).write(to: url, options: .atomic)
            report("已导出网页副本：\(url.lastPathComponent)", kind: .success)
        } catch {
            report("导出失败：\(UserFacingError.message(for: error))", kind: .error)
        }
    }

    private func exportRecoveryKit() {
        sync.revealOrCreateKey()
        guard let code = sync.transferCode else {
            report(sync.lastError ?? "恢复码暂时不可用，请先在钥匙串中创建。", kind: .error)
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出恢复说明"
        panel.nameFieldStringValue = "RiverDiary-恢复说明-\(DiaryEntry.dateFormatter.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = """
        河流日记恢复说明
        生成时间：\(Date().formatted(date: .numeric, time: .standard))

        恢复码：
        \(code)

        用途
        - 换 Mac、重装或恢复备份时，在「设置 → 隐私与备份」导入同一恢复码，再选择备份恢复。
        - 恢复码只保存在本机钥匙串；这个文件是明文，请放在加密磁盘或密码管理器，不要发到聊天群。
        - 没有恢复码，加密备份和同步对象都无法解密。

        步骤
        1. 安装同一版本的 River Diary。
        2. 打开「设置 → 隐私与备份」。
        3. 在同步密钥处粘贴恢复码并导入。
        4. 选择「恢复备份」，先点「检查备份文件」，确认内容与日期后再恢复。

        注意：恢复会替换当前本机数据；恢复前应用会自动保存一个恢复点。
        """
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            report("恢复说明已导出：\(url.lastPathComponent)。请把它和备份分开存放。", kind: .success)
        } catch {
            report("恢复说明导出失败：\(UserFacingError.message(for: error))", kind: .error)
        }
    }

    private var backupAgeWarning: String? {
        let now = Date().timeIntervalSince1970
        guard lastExportAt > 0 else {
            return "还没有导出过加密备份。建议先导出一份，并把恢复码保存在本机之外；没有恢复码，备份无法解密。"
        }
        let days = Int((now - lastExportAt) / 86_400)
        guard days >= 7 else { return nil }
        return "上次加密备份已是 \(days) 天前。换机或重装前，请再导出一份并确认恢复码可用。"
    }

    private func inspectBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.message = "选择 River Diary 生成的加密备份；检查不会修改当前数据"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let info = try store.validateFullBackup(at: url) { legacy, v2 in
                if let legacy { try AppDatabase.shared.validateEncryptedSnapshot(legacy) }
                if let v2 { try activity.validateV2Snapshot(v2) }
            }
            let date = info.exportedAt.formatted(date: .abbreviated, time: .shortened)
            let databases = [info.includesLegacyDatabase ? "兼容库" : nil, info.includesV2Database ? "事实库" : nil]
                .compactMap { $0 }.joined(separator: " + ")
            inspectionResult = "备份有效 · \(date) · 日记 \(info.entryCount) · 快记 \(info.quickCaptureCount) · 足迹 \(info.activityCount) · 信件 \(info.monthlyLetterCount)" +
                (databases.isEmpty ? "" : " · 含 \(databases)")
        } catch {
            inspectionResult = "校验失败：\(UserFacingError.message(for: error))"
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(exportedAs: "studio.riverdiary.mac.backup", conformingTo: .data)]
        panel.nameFieldStringValue = "RiverDiaryBackup-\(DiaryEntry.dateFormatter.string(from: Date()))"
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
            lastExportAt = Date().timeIntervalSince1970
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
            // 恢复后的 V2 活动证据必须与恢复后的实时层一致（legacy 备份没有
            // V2 快照，旧证据会残留）。
            activity.rebuildV2EvidenceAfterRestore()
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

private struct PlaceDecisionMacRow: View {
    let place: RiverPlace
    let onSave: (String, String) -> Void
    @State private var name: String
    @State private var type: String

    init(place: RiverPlace, onSave: @escaping (String, String) -> Void) {
        self.place = place
        self.onSave = onSave
        _name = State(initialValue: place.userDefinedName ?? place.mapName ?? "")
        _type = State(initialValue: place.semanticType ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack {
                Text(place.displayName).font(AppTypography.secondary())
                Spacer()
                Text(place.isUserConfirmed ? "已确认" : "候选")
                    .font(AppTypography.micro())
                    .foregroundStyle(place.isUserConfirmed ? AppTheme.accent : Color.secondaryInk)
            }
            if let address = place.mapAddress, !address.isEmpty {
                Text(address).font(AppTypography.micro()).foregroundStyle(Color.secondaryInk)
            }
            HStack(spacing: AppSpacing.sm) {
                TextField("地点名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField("类型，如 residence", text: $type)
                    .textFieldStyle(.roundedBorder)
                Button("保存决定") { onSave(name, type) }
                    .buttonStyle(.plain)
                    .smallAction()
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, AppSpacing.xs)
    }
}

private struct RiverMacDiagnosticsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
