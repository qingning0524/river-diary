import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var health: HealthKitStore
    @EnvironmentObject private var store: DiaryStore
    @EnvironmentObject private var drive: ICloudDriveStore
    @EnvironmentObject private var node: RiverNodeStore
    @State private var showsScoreResetConfirmation = false
    @State private var showFolderPicker = false
    @State private var syncKeyText = ""
    @State private var showsSyncKey = false
    @State private var backupDocument: RiverNodeBackupDocument?
    @State private var showsBackupExport = false
    @State private var showsBackupImport = false
    @State private var diagnosticDocument: RiverDiagnosticsDocument?
    @State private var showsDiagnosticExport = false
    @AppStorage("river.developerMode.enabled") private var developerModeEnabled = false

    var body: some View {
        NavigationStack {
            List {
                Section("系统集成") {
                    healthRow
                    screenTimeRowUnavailable
                    iCloudDriveRow
                }

                Section("应用活动") {
                    Text("在快捷指令中为微信、Safari 或 ChatGPT 分别创建“打开 App”和“关闭 App”个人自动化，动作为“记录应用活动”。事件会先写入本机。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    DisclosureGroup("查看配置步骤和应用标识") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("1. 打开“快捷指令”→“自动化”→“新建个人自动化”→“App”，选择一个应用。")
                            Text("2. 分别为“已打开”和“已关闭”各建一条自动化，并选择“立即运行”。")
                            Text("3. 添加 River Diary 的“记录应用活动”操作，填写显示名称、应用标识和事件类型 opened / closed。")
                            Text("微信 · com.tencent.xin")
                            Text("Safari · com.apple.mobilesafari")
                            Text("ChatGPT · com.openai.chat")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                    }
                    LabeledContent("事件存储", value: "本机 River Diary 数据库")
                }

                Section("位置记录") {
                    if let location = node.locationCollector {
                        LocationRecordingSettings(location: location)
                    } else {
                        Text(node.initializationError ?? "本地事件库未准备好。")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("网络 AI 分析") {
                    if let ai = node.aiStore {
                        IPhoneAISettings(ai: ai)
                    } else {
                        Text("本地事件库未准备好。")
                    }
                }

                Section("加密同步") {
                    LabeledContent("状态", value: node.syncStatus)
                    if let lastSyncAt = node.lastSyncAt {
                        LabeledContent("最近核对", value: lastSyncAt.formatted(date: .omitted, time: .shortened))
                    }
                    Button(node.isSyncing ? "正在同步…" : "立即同步并核对") {
                        node.synchronize(using: drive, localMoodScores: store.localMoodScoresByDate)
                    }
                    .disabled(node.isSyncing || !drive.hasAccess)

                    Toggle(
                        "附近设备快速复制",
                        isOn: Binding(
                            get: { node.isLANReplicating },
                            set: { node.setLANReplicationEnabled($0, using: drive) }
                        )
                    )
                    LabeledContent("局域网状态", value: node.lanSyncStatus)
                    Text("仅在你启用时与附近的 River Diary 设备交换已加密复制对象；同一密钥和文件夹仍用于最终核对。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button(showsSyncKey ? "隐藏密钥" : "显示或创建同步密钥") {
                        if !showsSyncKey {
                            node.revealOrCreateSyncKey()
                            node.restoreLANReplicationPreference(using: drive)
                        }
                        showsSyncKey.toggle()
                    }
                    if showsSyncKey, let code = node.keyTransferCode {
                        Text(code)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(3)
                        Button("复制同步密钥") {
                            UIPasteboard.general.string = code
                        }
                    }

                    TextField("粘贴另一设备的同步密钥", text: $syncKeyText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("导入同步密钥") {
                        node.importSyncKey(syncKeyText)
                        node.restoreLANReplicationPreference(using: drive)
                        syncKeyText = ""
                    }
                    .disabled(syncKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("两台设备选择同一个 iCloud Drive 文件夹，并导入同一密钥。密钥只保存在本机钥匙串；同步文件不包含明文密钥。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !node.devices.isEmpty {
                        ForEach(node.devices) { device in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.displayName).font(.subheadline)
                                    Text("\(device.platform) · \(device.lifecycle == .active ? "参与核对" : "已退役")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if device.lifecycle == .active && device.id.rawValue != node.deviceID {
                                    Button("退役") { node.retireDevice(device.id) }
                                        .tint(.red)
                                }
                            }
                        }
                    }
                    if node.unresolvedDecisionConflicts > 0 {
                        Text("有 \(node.unresolvedDecisionConflicts) 项并发修改；当前显示较新的用户决定，历史修改均保留。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("数据") {
                    LabeledContent("本机设备 ID", value: node.deviceID)
                    LabeledContent("今天本机事件", value: "\(node.eventCount)")
                    if let error = node.initializationError {
                        Text(error).foregroundStyle(.red)
                    }
                    if let error = node.lastCaptureError {
                        Text(error).foregroundStyle(.red)
                    }
                    LabeledContent("记录天数", value: "\(store.entries.count)")
                    LabeledContent("数据生成时间", value: store.data?.generated ?? "—")
                    LabeledContent("远端数据时间", value: store.remoteGenerated ?? "—")
                    LabeledContent("iCloud 文件夹", value: drive.folderDisplayName ?? "未选择")
                    LabeledContent("同步状态", value: store.syncStatus)
                    Button("读取旧版共享快照") {
                        Task {
                            await store.refreshFromICloud()
                        }
                    }
                    .disabled(!drive.hasAccess)
                    LabeledContent("评分存储", value: "修改通过加密同步复制到已登记设备")
                    Button {
                        showsScoreResetConfirmation = true
                    } label: {
                        Text("还原本地评分")
                            .foregroundStyle(.red)
                    }
                    .disabled(!store.hasLocalScoreEdits)
                }

                Section("本地备份") {
                    Text("备份包含原始事件、用户决定和 Artifact，并使用同步密钥加密。重装后恢复需要保留或重新导入同一同步密钥。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("导出加密本地备份") {
                        if !showsSyncKey {
                            node.revealOrCreateSyncKey()
                            showsSyncKey = true
                        }
                        do {
                            backupDocument = RiverNodeBackupDocument(data: try node.makeEncryptedLocalBackup())
                            showsBackupExport = true
                        } catch {
                            node.setBackupMessage("备份无法导出：\(error.localizedDescription)")
                        }
                    }
                    Button("合并本地备份") { showsBackupImport = true }
                    if let message = node.backupMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(message.hasPrefix("备份无法") ? Color.red : Color.secondary)
                    }
                }

                Section {
                    Text("HealthKit 只把已授权的睡眠和运动日汇总保存在本机；启用加密同步后才会复制到你的共享文件夹。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("隐私原则")
                }

                Section("开发者模式") {
                    Toggle("显示 Developer Diagnostics", isOn: $developerModeEnabled)
                    if developerModeEnabled {
                        developerDiagnostics
                    }
                }
            }
            .navigationTitle("设置")
            .confirmationDialog(
                "还原本地评分",
                isPresented: $showsScoreResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("还原全部评分", role: .destructive) {
                    store.resetLocalScores()
                }
            } message: {
                Text("所有修改过的评分都会恢复为导入时的数值。")
            }
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        drive.handlePickedFolder(url)
                        node.restoreLANReplicationPreference(using: drive)
                    }
                case .failure(let error):
                    drive.lastError = error.localizedDescription
                }
                Task {
                    await store.refreshFromICloud()
                    node.synchronize(using: drive, localMoodScores: store.localMoodScoresByDate)
                }
            }
            .fileExporter(
                isPresented: $showsBackupExport,
                document: backupDocument,
                contentType: .data,
                defaultFilename: "RiverDiary-iPhone-\(Date.now.formatted(.iso8601.year().month().day())).riverbackup"
            ) { result in
                switch result {
                case .success(let url): node.setBackupMessage("加密备份已导出到 \(url.lastPathComponent)")
                case .failure(let error): node.setBackupMessage("备份无法导出：\(error.localizedDescription)")
                }
            }
            .fileImporter(
                isPresented: $showsBackupImport,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        node.restoreEncryptedLocalBackup(try Data(contentsOf: url))
                    } catch {
                        node.setBackupMessage("备份无法读取：\(error.localizedDescription)")
                    }
                case .failure(let error): node.setBackupMessage("备份无法读取：\(error.localizedDescription)")
                }
            }
            .fileExporter(
                isPresented: $showsDiagnosticExport,
                document: diagnosticDocument,
                contentType: .json,
                defaultFilename: "RiverDiary-Diagnostics.json"
            ) { result in
                switch result {
                case .success(let url): node.setDiagnosticActionMessage("诊断报告已导出到 \(url.lastPathComponent)。")
                case .failure(let error): node.setDiagnosticActionMessage("诊断报告导出失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private var developerDiagnostics: some View {
        let database = node.database
        let events = (try? database?.allEvents()) ?? []
        let operations = (try? database?.allStateOperations()) ?? []
        let artifactCount = (try? database?.allArtifactRevisionCount()) ?? 0
        let canonicalArtifacts = (try? database?.canonicalArtifactRevisions()) ?? []
        let sessions = (try? database?.allSessions()) ?? []
        let frontier = (try? database?.ownedFrontier()) ?? nil
        let pendingHabitCount = database?.sharedUserRecords.filter {
            $0.kind == .habitCard && ($0.status == "bundled" || $0.status == "shown")
        }.count ?? 0
        let pendingMemoryCount = database?.sharedUserRecords.filter {
            $0.kind == .memory && database?.memoryConfirmation(for: $0.id)?.confirmed != true
        }.count ?? 0
        let lastLocation = events.filter { $0.kind.hasPrefix("location.") }.max { $0.observedAt < $1.observedAt }
        let lastGeocode = events.filter { $0.kind == "location.placeCandidate" }.max { $0.recordedAt < $1.recordedAt }
        let lastIntent = events.filter { $0.source == "shortcuts" }.max { $0.recordedAt < $1.recordedAt }

        return Group {
            LabeledContent("Device ID", value: node.deviceID)
            LabeledContent("Database version", value: database == nil ? "不可用" : "4")
            LabeledContent("Event / Session / Place", value: "\(events.count) / \(sessions.count) / \(database?.places.count ?? 0)")
            LabeledContent("State Operations", value: "\(operations.count)")
            LabeledContent("Artifact / Canonical / Stale", value: "\(artifactCount) / \(canonicalArtifacts.count) / \((try? database?.staleArtifactCount()) ?? 0)")
            LabeledContent("Pending confirmations", value: "习惯卡 \(pendingHabitCount) · 记忆 \(pendingMemoryCount)；通用中心未接入")
            LabeledContent("Imported objects", value: "\((try? database?.importedReplicationObjectCount()) ?? 0)")
            LabeledContent("最近导出 / 导入", value: "E \(node.syncReport?.exportedEventBatches ?? 0)/\(node.syncReport?.importedEventBatches ?? 0) · O \(node.syncReport?.exportedOperationBatches ?? 0)/\(node.syncReport?.importedOperationBatches ?? 0) · A \(node.syncReport?.exportedArtifactRevisions ?? 0)/\(node.syncReport?.importedArtifactRevisions ?? 0)")
            LabeledContent("Event / Operation frontier", value: "\(frontier?.events ?? 0) / \(frontier?.operations ?? 0)")
            LabeledContent("iCloud directory", value: drive.folderDisplayName ?? "未选择")
            LabeledContent("Bookmark", value: drive.hasAccess ? "可访问" : "未授权或失效")
            LabeledContent("LAN transport", value: node.isLANReplicating ? node.lanSyncStatus : "未启用")
            LabeledContent("最近导出 / 导入", value: "\(node.lastSuccessfulExportAt?.formatted(date: .abbreviated, time: .shortened) ?? "—") / \(node.lastImportAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")")
            LabeledContent("最近 reconciliation / verified", value: "\(node.lastSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "—") / \(node.lastVerifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")")
            LabeledContent("Canonical digest", value: (try? database?.canonicalStateDigest()) ?? "不可用")
                .lineLimit(2)
                .textSelection(.enabled)
            LabeledContent("Missing sequences", value: node.syncReport.map { report in
                report.missingSequenceGaps.isEmpty
                    ? "无"
                    : report.missingSequenceGaps.map { "\($0.deviceID.rawValue)/\($0.stream) \($0.first)-\($0.last)" }.joined(separator: ", ")
            } ?? "最近一次扫描未运行")
            LabeledContent("Integrity failures", value: node.syncReport?.integrityFailures.isEmpty == false ? node.syncReport!.integrityFailures.joined(separator: "\n") : "无")
            LabeledContent("Location authorization", value: node.locationCollector?.statusText ?? "不可用")
            LabeledContent("Last location event", value: lastLocation?.observedAt.formatted(date: .abbreviated, time: .shortened) ?? "—")
            LabeledContent("Last geocode", value: lastGeocode?.recordedAt.formatted(date: .abbreviated, time: .shortened) ?? "—")
            LabeledContent("Map candidate records", value: "\(events.filter { $0.kind == "location.placeCandidate" }.count)")
            LabeledContent("Last App Activity Intent", value: lastIntent?.recordedAt.formatted(date: .abbreviated, time: .shortened) ?? "—")
            LabeledContent("AI job", value: ((try? database?.latestAnalysisJob()) ?? nil).map { "\($0.status.rawValue) · \($0.logicalKey) · attempt \($0.attempt)" } ?? "暂无已记录任务")

            Button("Generate Test Event") { node.generateDiagnosticTestEvent() }
            Button("Request Location Sample") { node.locationCollector?.requestPrecisionSample() }
                .disabled(node.locationCollector == nil)
            Button("Flush Event Batch") { node.runDiagnosticSync(using: drive, label: "Flush Event Batch") }
            Button("Flush State Operations") { node.runDiagnosticSync(using: drive, label: "Flush State Operations") }
            Button("Scan / Import / Reconcile / Verify") { node.runDiagnosticSync(using: drive, label: "Directory Scan and Reconciliation") }
            Button("Rebuild Sessions / Places / Timeline") { node.rebuildDiagnosticProjection() }
            Button("Invalidate AI Artifacts") { node.invalidateArtifactsForDiagnostics() }
            Button("Export Diagnostics Report") {
                guard let data = node.reportDeveloperDiagnostics(
                    selectedDirectory: drive.folderDisplayName,
                    bookmarkAvailable: drive.hasAccess,
                    locationAuthorization: node.locationCollector?.statusText ?? "不可用"
                ) else {
                    node.setDiagnosticActionMessage("无法读取诊断快照。")
                    return
                }
                diagnosticDocument = RiverDiagnosticsDocument(data: data)
                showsDiagnosticExport = true
            }
            if let message = node.diagnosticActionMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            if let failures = node.syncReport?.integrityFailures, !failures.isEmpty {
                ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                    Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
    }

    private var healthRow: some View {
        HStack {
            Label("Apple 健康", systemImage: "heart.text.square.fill")
            Spacer()
            if health.isLoading {
                ProgressView()
            } else if health.isAuthorized {
                Button("已连接 · \(health.nights.count) 晚 · \(health.exerciseDays.count) 天") { health.loadHealth() }
            } else {
                Button("连接") { health.requestAuthorization() }
            }
        }
    }

    private var screenTimeRowUnavailable: some View {
        HStack {
            Label("屏幕使用时间", systemImage: "iphone.gen3.radiowaves.left.and.right")
            Spacer()
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
        }
    }

    private var iCloudDriveRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("iCloud Drive 同步", systemImage: "icloud")
                Spacer()
                if drive.isWriting {
                    ProgressView()
                } else if drive.hasAccess {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("选择文件夹") { showFolderPicker = true }
                }
            }

            if let error = drive.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if drive.hasAccess {
                Text("已连接 \(drive.folderDisplayName ?? "")。新事件、用户决定和分析结果以加密对象同步；旧版共享快照只用于兼容读取。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("首次使用需选择 iCloud Drive 文件夹。未连接期间会先保存在本机，连接后再同步。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let syncError = store.syncError {
                Text(syncError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct RiverNodeBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw RiverLocalDatabaseError.sql("备份文件内容为空。")
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct RiverDiagnosticsDocument: FileDocument {
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

private struct LocationRecordingSettings: View {
    @ObservedObject var location: IPhoneLocationCollector

    var body: some View {
        Toggle(
            "记录到访和显著移动",
            isOn: Binding(
                get: { location.isEnabled },
                set: { location.setEnabled($0) }
            )
        )
        Text("开启后使用 Core Location 的到访和低功耗显著位置变化；不会持续使用高精度 GPS。位置会先保存在本机。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        LabeledContent("系统授权", value: location.statusText)
        LabeledContent("后台到访", value: location.backgroundDeliveryAvailable ? "系统允许" : "需“始终”授权")
        HStack {
            Button("记录一次当前位置") { location.requestPrecisionSample() }
                .disabled(!location.isEnabled)
            Spacer()
            if let name = location.latestLocationName {
                Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        if let error = location.lastError {
            Text(error).font(.caption).foregroundStyle(.orange)
        }
    }
}

private struct IPhoneAISettings: View {
    @ObservedObject var ai: IPhoneAIStore

    var body: some View {
        Toggle("同意向网络 AI 发送所选资料", isOn: $ai.allowsNetworkAnalysis)
        Text("默认关闭。开启后，只有你主动点“分析”时才会向下方配置的 API 发送今天的已选事件。Ollama / LM Studio 的本机地址不出设备。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        TextField("OpenAI 兼容 API 地址", text: $ai.endpoint)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        TextField("模型名称", text: $ai.model)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        SecureField("API Key", text: $ai.apiKeyInput)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        HStack {
            Button(ai.hasAPIKey ? "更新并保存 API Key" : "保存 API Key") { ai.saveAPIKey() }
                .disabled(ai.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer()
            if ai.hasAPIKey {
                Button("移除") { ai.removeAPIKey() }
                    .foregroundStyle(.red)
            } else {
                Text("尚未保存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if ai.hasAPIKey {
            Text("API Key 仅保存在本机钥匙串。网络请求仅在你同意后发出，并要求使用 HTTPS。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Toggle("包含地点名称", isOn: $ai.includePlaces)
        Toggle("包含健康日汇总", isOn: $ai.includeHealth)
        Toggle("包含手动文本记录", isOn: $ai.includeManualText)
        if let error = ai.errorMessage {
            Text(error).font(.caption).foregroundStyle(.orange)
        }
    }
}
