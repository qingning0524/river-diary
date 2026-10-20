import SwiftUI
import UIKit
import UniformTypeIdentifiers
import RiverDiaryCore

private enum SettingsInputField: Hashable {
    case syncKey
    case aiEndpoint
    case aiModel
    case aiKey
}

struct SettingsView: View {
    @Environment(\.riverTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    @EnvironmentObject private var themeStore: RiverThemeStore
    @EnvironmentObject private var health: HealthKitStore
    @EnvironmentObject private var store: DiaryStore
    @EnvironmentObject private var drive: ICloudDriveStore
    @EnvironmentObject private var account: RiverAccountSessionStore
    @EnvironmentObject private var coordinator: RiverAppCoordinator
    var embedded = false
    @EnvironmentObject private var node: RiverNodeStore
    @StateObject private var reminder = RiverReminderStore()
    @State private var showsScoreResetConfirmation = false
    @State private var showFolderPicker = false
    @State private var syncKeyText = ""
    @State private var showsSyncKey = false
    @State private var backupDocument: RiverNodeBackupDocument?
    @State private var showsBackupExport = false
    @State private var showsBackupImport = false
    @State private var diagnosticDocument: RiverDiagnosticsDocument?
    @State private var showsDiagnosticExport = false
    @State private var showsJournal = false
    @State private var pendingJournalEditDate: Date?
    @State private var journalPresentation: RiverJournalPresentation?
    @State private var journalFeedback: RiverFeedback?
    @State private var showsInsights = false
    @State private var devicePendingRetirement: RiverDeviceID?
    @FocusState private var focusedSettingsField: SettingsInputField?
    @AppStorage("river.developerMode.enabled") private var developerModeEnabled = false

    private var themeStoreIcon: String { themeStore.selectedThemeID.symbol }
    private var themeStoreName: String { themeStore.selectedThemeName }

    var body: some View {
        Group { if embedded { rootPage } else { NavigationStack { rootPage } } }
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
                    guard accessed else {
                        node.setBackupMessage("无法访问所选备份文件，请重新选择该文件。")
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    do {
                        node.restoreEncryptedLocalBackup(try CoordinatedFileIO.read(url))
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
            .sheet(isPresented: $showsJournal, onDismiss: {
            guard let date = pendingJournalEditDate else { return }
            pendingJournalEditDate = nil
            if embedded {
                coordinator.presentJournal(on: date)
            } else {
                journalPresentation = RiverJournalPresentation(date: date)
            }
        }) {
            JournalView(onEditRequest: { date in
                pendingJournalEditDate = date
                showsJournal = false
            })
        }
            .sheet(item: $journalPresentation) { presentation in
                RiverJournalComposerView(date: presentation.date) {
                    coordinator.journalSaveRevision &+= 1
                    node.objectWillChange.send()
                    journalFeedback = .success("已保存在本机。")
                }
            }
            .riverFeedback($journalFeedback)
            .sheet(isPresented: $showsInsights) { InsightsView() }    }

    private var profileName: String { account.accountEmail?.split(separator: "@").first.map(String.init) ?? "River Diary" }
    private var pendingCount: Int { (node.database?.sharedUserRecords ?? []).filter { ($0.kind == .pendingConfirmation && $0.status == "pending") || ($0.kind == .habitCard && ["bundled", "shown"].contains($0.status)) }.count }
    private var connectedSources: Int { [health.isAuthorized, node.photoAnalyzer?.isEnabled == true, node.locationCollector?.isEnabled == true].filter { $0 }.count }
    private var recordedDays: Int { Set(store.entries.map(\.date) + (node.database?.sharedUserRecords ?? []).compactMap { $0.journalEntryContent?.dayKey }).count }
    private var archiveStatus: String {
        guard node.database != nil else { return "本机档案暂不可用" }
        if !drive.hasAccess { return "本机档案 · 尚未连接云端文件夹" }
        return node.syncStatus
    }
    private var rootPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        RiverSystemSignature()
                        Text("设置").font(theme.titleFont).accessibilityIdentifier("river.settings.title")
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(theme.ink)
                    .accessibilityLabel("完成设置").accessibilityIdentifier("river.settings.close")
                }
                NavigationLink { settingsPage("账户与权益") { Section { AccountSettingsCard() } } } label: {
                    VStack(alignment: .leading, spacing: 16) {
                        let identityLayout = textSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
                        identityLayout {
                            Text(String(profileName.prefix(1)).uppercased())
                                .font(.system(size: 24, weight: .medium)).foregroundStyle(theme.palette.onAccent)
                                .frame(width: 56, height: 56).background(theme.accent, in: Circle())
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(account.isSignedIn ? profileName : "你的 River 账户")
                                    .font(theme.textFont(20, relativeTo: .title3, weight: .medium))
                                Text(account.accountEmail ?? "登录后管理你的账户与权益")
                                    .font(theme.textFont(13)).foregroundStyle(theme.secondaryInk)
                                    .lineLimit(textSize.isAccessibilitySize ? nil : 2)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if !textSize.isAccessibilitySize {
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.secondaryInk)
                            }
                        }
                        Divider().overlay(theme.separator)
                        VStack(alignment: .leading, spacing: 8) {
                            Label(node.database == nil ? "本机档案暂不可用" : "这台 iPhone · \(recordedDays) 天的记录", systemImage: "iphone")
                            Label(archiveStatus, systemImage: drive.hasAccess ? "icloud" : "icloud.slash")
                        }
                        .font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
                        .accessibilityIdentifier("river.settings.archive.status")
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.separator, lineWidth: theme.borderWidth) }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("river.settings.account")
                settingsGroup("日常记录") {
                    reminderRow
                    settingsDivider
                    sourceLink("记录来源与授权", value: connectedSources == 0 ? "由你选择" : "\(connectedSources) 项已连接", symbol: "sensor.tag.radiowaves.forward")
                    settingsDivider
                    photoControl
                    settingsDivider
                    locationRow
                    settingsDivider
                    appearanceLink
                }
                settingsGroup("River 与资料") {
                    aiLink
                    settingsDivider
                    Button { coordinator.openConfirmations() } label: {
                        settingRow("待确认的理解", value: pendingCount == 0 ? "暂无待办" : "\(pendingCount) 项", symbol: "questionmark.circle")
                    }.buttonStyle(.plain)
                    settingsDivider
                    Button { showsJournal = true } label: { settingRow("日记档案", symbol: "book") }.buttonStyle(.plain).accessibilityIdentifier("river.settings.journals")
                    settingsDivider
                    Button { showsInsights = true } label: { settingRow("情绪与长期回顾", symbol: "chart.xyaxis.line") }.buttonStyle(.plain)
                }
                settingsGroup("账户及隐私") {
                    syncLink("云端档案与设备同步")
                    settingsDivider
                    dataLink("隐私、权限与备份", symbol: "checkmark.shield")
                    settingsDivider
                    NavigationLink { dataSettings } label: { settingRow("导出我的记录", symbol: "square.and.arrow.up") }
                    settingsDivider
                    NavigationLink { helpPage } label: { settingRow("使用帮助", symbol: "questionmark.circle") }
                    settingsDivider
                    NavigationLink { aboutPage } label: { settingRow("关于 River OS", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, symbol: "water.waves") }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("生活归你，记忆也归你。")
                        .font(theme.textFont(14, weight: .medium)).foregroundStyle(theme.ink)
                    Text("账户服务与个人档案分开管理。记录先保存在本机；连接共享文件夹后，按当前同步状态核对加密档案。")
                        .font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk).fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 8)
            }
            .padding(.horizontal, theme.pageGutter).padding(.top, 16).padding(.bottom, 32)
        }
        .foregroundStyle(theme.ink).background(theme.canvas).navigationTitle("设置").toolbar(.hidden, for: .navigationBar)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focusedSettingsField = nil }.accessibilityIdentifier("settings.keyboardDone") } }
        .scrollDismissesKeyboard(.interactively)
    }
    private var settingsDivider: some View {
        Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 56)
    }
    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(theme.sectionFont).foregroundStyle(theme.ink).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous)
                        .strokeBorder(theme.separator.opacity(0.75), lineWidth: theme.borderWidth)
                }
        }
    }
    private func settingRow(_ title: String, value: String? = nil, symbol: String) -> some View {
        HStack(spacing: 12) {
            RiverIconChip(symbol: symbol, size: 34)
            Text(title).font(theme.textFont(15, weight: .medium)).foregroundStyle(theme.ink)
            Spacer(minLength: 6)
            if let value, !value.isEmpty { Text(value).font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk).lineLimit(1) }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondaryInk.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52).contentShape(Rectangle())
    }
    private func sourceLink(_ title: String, value: String, symbol: String = "link") -> some View {
        NavigationLink { sourceSettings } label: { settingRow(title, value: value, symbol: symbol) }
            .accessibilityIdentifier(title == "应用活动" ? "river.settings.apps" : "river.settings.sources")
    }
    private var aiLink: some View {
        NavigationLink { aiSettings } label: {
            settingRow("AI 服务与资料范围", value: node.aiStore?.usesLocalEndpoint == true ? "本机模型" : node.aiStore?.hasAPIKey == true ? "已配置" : "待配置", symbol: "water.waves")
        }.accessibilityIdentifier("river.settings.ai")
    }
    private var appearanceLink: some View {
        NavigationLink { RiverThemeGalleryView() } label: { settingRow("阅读与外观", value: themeStoreName, symbol: themeStoreIcon) }.accessibilityIdentifier("river.theme.open")
    }
    private func syncLink(_ title: String) -> some View {
        NavigationLink { syncSettings } label: { settingRow(title, value: drive.hasAccess ? node.lastVerifiedAt == nil ? "待核对" : "查看状态" : "本机记录", symbol: "icloud") }.accessibilityIdentifier("river.settings.sync")
    }
    private func dataLink(_ title: String, symbol: String) -> some View {
        NavigationLink { dataSettings } label: { settingRow(title, symbol: symbol) }.accessibilityIdentifier("river.settings.data")
    }
    private var photoControl: some View {
        HStack(spacing: 12) {
            RiverIconChip(symbol: "photo", size: 34)
            Text("自动整理照片").font(theme.textFont(15, weight: .medium)); Spacer()
            if let photos = node.photoAnalyzer {
                Toggle("自动整理照片", isOn: Binding(get: { photos.isEnabled }, set: { value in Task { await photos.setEnabled(value) } })).labelsHidden().frame(width: 52, height: 44)
            } else { Text("暂不可用").font(theme.textFont(12)).foregroundStyle(theme.secondaryInk) }
        }.padding(.horizontal, 14).frame(minHeight: 52)
    }
    private var locationRow: some View {
        HStack(spacing: 12) {
            RiverIconChip(symbol: "location", size: 34)
            Text("自动收集足迹").font(theme.textFont(15, weight: .medium)); Spacer()
            if let location = node.locationCollector {
                Toggle("自动收集足迹", isOn: Binding(get: { location.isEnabled }, set: { location.setEnabled($0) })).labelsHidden().frame(width: 52, height: 44)
            } else { Text("暂不可用").font(theme.textFont(12)).foregroundStyle(theme.secondaryInk) }
        }.padding(.horizontal, 14).frame(minHeight: 52)
    }
    private var reminderRow: some View {
        HStack(spacing: 12) {
            RiverIconChip(symbol: "bell", size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("晚间记录提醒").font(theme.textFont(15, weight: .medium))
                Text(reminder.message ?? "每天 21:30，给今天留一点时间。").font(theme.textFont(11, relativeTo: .caption)).foregroundStyle(theme.secondaryInk)
            }
            Spacer()
            Toggle("晚间记录提醒", isOn: Binding(get: { reminder.isEnabled }, set: { value in Task { await reminder.setEnabled(value) } })).labelsHidden().frame(width: 52, height: 44)
        }.padding(.horizontal, 14).frame(minHeight: 52)
    }
    private var helpPage: some View {
        settingsPage("使用帮助") {
            Section("开始记录") { Text("在今天页写日记；在记录页查看已有的活动、时间与来源。记忆页按日记、个人记忆和地点归档。") }
            Section("确认与连接") { Text("River 里的待确认线索可看依据、纠正与稍后处理。AI 地址、模型和密钥在 AI 连接中配置。") }
            Section("记录") { Button("日记与过往记录") { showsJournal = true }; Button("情绪与长期回顾") { showsInsights = true } }
        }
    }
    private var aboutPage: some View { settingsPage("关于 River") { Section { Text("River Diary").font(theme.titleFont); Text("生活归你，记录也归你。"); Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")") }; Section { Button("日记与过往记录") { showsJournal = true }; Button("情绪与长期回顾") { showsInsights = true } } } }

    private func settingsEntry(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(theme.accentText).frame(width: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(theme.ink)
                Text(detail).font(.footnote).foregroundStyle(theme.secondaryInk).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(minHeight: 52)
    }
    // Limit destination metadata depth; the physical Swift runtime overflowed
    // while resolving the nested generic account destination.
    private func settingsPage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> AnyView {
        AnyView(List { content() }.listStyle(.insetGrouped).listRowBackground(theme.surface).foregroundStyle(theme.ink).navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .scrollDismissesKeyboard(.interactively).scrollContentBackground(.hidden).background(theme.canvas).tint(theme.accentText))
    }
    private var sourceSettings: some View {
        settingsPage("记录来源") {
                Section("照片与运动线索") {
                    if let photos = node.photoAnalyzer {
                        IPhonePhotoAnalysisSettings(photos: photos)
                    }
                    if let motion = node.motionCollector {
                        IPhoneMotionSettings(motion: motion)
                    }
                }

                Section("系统集成") {
                    healthRow
                    screenTimeRowUnavailable
                    iCloudDriveRow
                }

                Section("应用活动") {
                    Text("在快捷指令中为微信、Safari 或 ChatGPT 分别创建“打开 App”和“关闭 App”个人自动化，动作为“记录应用活动”。事件会先写入本机。")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryInk)
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
                        .foregroundStyle(theme.secondaryInk)
                        .padding(.vertical, 4)
                    }
                    LabeledContent("事件存储", value: "本机 River Diary 数据库")
                }

                Section("位置记录") {
                    if let location = node.locationCollector {
                        LocationRecordingSettings(location: location)
                    } else {
                        Text(node.initializationError ?? "本地事件库未准备好。")
                            .foregroundStyle(theme.secondaryInk)
                    }
                }


        }
    }
    private var aiSettings: some View {
        settingsPage("AI 服务与资料范围") {
            if let ai = node.aiStore { IPhoneAISettings(ai: ai, focusedField: $focusedSettingsField) }
            else { Text("本机记录库暂不可用，请重试打开。") }
        }
    }
    private var syncSettings: some View {
        settingsPage("设备与同步") {
                Section("加密同步") {
                    LabeledContent("状态", value: node.syncStatus)
                        .accessibilityIdentifier("river.syncStatus")
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
                        .foregroundStyle(theme.secondaryInk)

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
                        .focused($focusedSettingsField, equals: .syncKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { focusedSettingsField = nil }
                    Button("导入同步密钥") {
                        node.importSyncKey(syncKeyText)
                        node.restoreLANReplicationPreference(using: drive)
                        syncKeyText = ""
                    }
                    .disabled(syncKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("两台设备选择同一个 iCloud Drive 文件夹，并导入同一密钥。密钥只保存在本机钥匙串；同步文件不包含明文密钥。")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryInk)
                    if !node.devices.isEmpty {
                        ForEach(node.devices) { device in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.displayName).font(.subheadline)
                                    Text("\(device.platform) · \(device.lifecycle == .active ? "参与核对" : "已退役")")
                                        .font(.caption)
                                        .foregroundStyle(theme.secondaryInk)
                                }
                                Spacer()
                                if device.lifecycle == .active && device.id.rawValue != node.deviceID {
                                    Button("退役") { devicePendingRetirement = device.id }
                                        .tint(theme.danger)
                                }
                            }
                        }
                    }
                    if node.unresolvedDecisionConflicts > 0 {
                        Text("有 \(node.unresolvedDecisionConflicts) 项并发修改；当前显示较新的用户决定，历史修改均保留。")
                            .font(.caption)
                            .foregroundStyle(theme.warning)
                    }
                }


        }
    }
    private var dataSettings: some View {
        settingsPage("资料与备份") {
                Section("数据") {
                    LabeledContent("本机设备 ID", value: node.deviceID)
                    LabeledContent("今天本机事件", value: "\(node.eventCount)")
                    if let error = node.initializationError {
                        Text(error).foregroundStyle(theme.danger)
                    }
                    if let error = node.lastCaptureError {
                        Text(error).foregroundStyle(theme.danger)
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
                            .foregroundStyle(theme.danger)
                    }
                    .disabled(!store.hasLocalScoreEdits)
                }


                Section("本地备份") {
                    Text("备份包含原始事件、用户决定和 Artifact，并使用同步密钥加密。重装后恢复需要保留或重新导入同一同步密钥。")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryInk)
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
                            .foregroundStyle(message.hasPrefix("备份无法") ? theme.danger : theme.secondaryInk)
                    }
                }

                Section {
                    Text("HealthKit 只把已授权的睡眠和运动日汇总保存在本机；启用加密同步后才会复制到你的共享文件夹。")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryInk)
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
            LabeledContent(
                "Database version",
                value: database == nil ? "不可用" : "\(RiverLocalDatabase.currentSchemaVersion)"
            )
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
                Text(message).font(.footnote).foregroundStyle(theme.secondaryInk)
            }
            if let failures = node.syncReport?.integrityFailures, !failures.isEmpty {
                ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                    Text(failure).font(.caption).foregroundStyle(theme.danger).textSelection(.enabled)
                }
            }
        }
    }

    private var healthRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Apple 健康", systemImage: "heart.text.square.fill")
            if health.isLoading { ProgressView("正在读取健康记录…") }
            else if health.isAuthorized {
                Text("已读取 \(health.nights.count) 晚睡眠 · \(health.exerciseDays.count) 天运动").font(.footnote).foregroundStyle(theme.secondaryInk)
                Button("刷新健康记录") { health.loadHealth() }.frame(minHeight: 44)
            } else {
                Button("连接 Apple 健康") { health.requestAuthorization() }.frame(minHeight: 44)
            }
        }
    }

    private var screenTimeRowUnavailable: some View {
        HStack {
            Label("屏幕使用时间", systemImage: "iphone.gen3.radiowaves.left.and.right")
            Spacer()
            Image(systemName: "lock.fill").foregroundStyle(theme.secondaryInk)
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
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
                }
            }

            if !drive.hasAccess && !drive.isWriting {
                Button("选择 iCloud Drive 文件夹") { showFolderPicker = true }.frame(minHeight: 44)
            }
            if let error = drive.lastError {
                Text(error).font(.caption).foregroundStyle(theme.danger)
            } else if drive.hasAccess {
                Text("已连接 \(drive.folderDisplayName ?? "")。新事件、用户决定和分析结果以加密对象同步；旧版共享快照只用于兼容读取。")
                    .font(.caption).foregroundStyle(theme.secondaryInk)
            } else {
                Text("首次使用需选择 iCloud Drive 文件夹。未连接期间会先保存在本机，连接后再同步。")
                    .font(.caption).foregroundStyle(theme.secondaryInk)
            }
            if let syncError = store.syncError {
                Text(syncError)
                    .font(.caption)
                    .foregroundStyle(theme.danger)
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
    @Environment(\.riverTheme) private var theme
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
            .foregroundStyle(theme.secondaryInk)
        LabeledContent("系统授权", value: location.statusText)
        LabeledContent("后台到访", value: location.backgroundDeliveryAvailable ? "系统允许" : "需“始终”授权")
        HStack {
            Button(location.isRequestingPrecisionSample ? "正在获取高精度位置…" : "记录一次当前位置") {
                location.requestPrecisionSample()
            }
            .disabled(!location.isEnabled || location.isRequestingPrecisionSample)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let name = location.latestLocationName {
                    Text(name).font(.caption).foregroundStyle(theme.secondaryInk).lineLimit(1)
                }
                if let accuracy = location.latestSampleAccuracyMeters {
                    Text("位置误差范围约 ±\(Int(accuracy.rounded())) 米")
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryInk)
                }
            }
        }
        if let error = location.lastError {
            Text(error).font(.caption).foregroundStyle(theme.warning)
        }
    }
}

private struct IPhoneAISettings: View {
    @Environment(\.riverTheme) private var theme
    @ObservedObject var ai: IPhoneAIStore
    @FocusState.Binding var focusedField: SettingsInputField?

    @State private var configurationResult: String?
    var body: some View {
        Section {
            HStack {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(ai.hasAPIKey || ai.usesLocalEndpoint ? theme.accentText : theme.secondaryInk)
                Text(ai.hasAPIKey ? "API Key 已保存在本机" : ai.usesLocalEndpoint ? "本机模型 · 不需要网络密钥" : "尚未绑定 API Key")
                    .font(.footnote).foregroundStyle(theme.secondaryInk).accessibilityIdentifier("river.ai.key.status")
            }.frame(minHeight: 44)
        }
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("服务地址").font(.footnote).foregroundStyle(theme.secondaryInk)
                TextField("API 基础地址或完整接口地址", text: $ai.endpoint)
                    .accessibilityIdentifier("river.ai.endpoint").focused($focusedField, equals: .aiEndpoint)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).submitLabel(.done).onSubmit { focusedSettingsFieldDone() }
            }.padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 8) {
                Text("模型名称").font(.footnote).foregroundStyle(theme.secondaryInk)
                TextField("模型名称", text: $ai.model).accessibilityIdentifier("river.ai.model").focused($focusedField, equals: .aiModel)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done).onSubmit { focusedSettingsFieldDone() }
            }.padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key").font(.footnote).foregroundStyle(theme.secondaryInk)
                SecureField("API Key", text: $ai.apiKeyInput).accessibilityIdentifier("river.ai.key").focused($focusedField, equals: .aiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done).onSubmit { focusedSettingsFieldDone() }
            }.padding(.vertical, 8)
            Button(ai.hasAPIKey ? "更新并保存 API Key" : "保存 API Key") { ai.saveAPIKey(); focusedSettingsFieldDone() }
                .frame(minHeight: 44).disabled(ai.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("river.ai.key.save")
            Button("检查配置") { configurationResult = ai.configurationIssue() ?? "配置字段已齐全，尚未验证服务连接。" }
                .frame(minHeight: 44).accessibilityIdentifier("river.ai.configuration.check")
            if let configurationResult { Text(configurationResult).font(.callout).foregroundStyle(theme.secondaryInk).accessibilityIdentifier("river.ai.configuration.result") }
            if ai.hasAPIKey { Button("移除 API Key", role: .destructive) { ai.removeAPIKey() }.frame(minHeight: 44) }
        } header: { Text("服务与模型") } footer: { Text("兼容 OpenAI 接口的服务均可填写。地址和模型在本机保存；密钥存入本机钥匙串。").font(.footnote) }
        Section {
            Toggle("同意向网络 AI 发送所选资料", isOn: $ai.allowsNetworkAnalysis)
        } header: { Text("联网授权") } footer: { Text("默认关闭。开启后，所选记录才会发送到你绑定的服务。本机模型使用本机地址。").font(.footnote) }
        Section {
            Toggle("包含手写日记和手动文本", isOn: $ai.includeManualText)
            Toggle("River 对话包含共享记忆与回答", isOn: $ai.includeSharedMemories)
            Toggle("包含地点名称", isOn: $ai.includePlaces)
            Toggle("包含健康日汇总", isOn: $ai.includeHealth)
            Toggle("包含本机识别的照片标签", isOn: $ai.includePhotoObservations)
        } header: { Text("可使用的记录") } footer: { Text("关闭某一项后，它不会进入网络 AI 的分析和回答。原始记录仍保留在本机。").font(.footnote) }
        Section("照片分析") {
            Toggle("允许当前 AI 看最近照片并估算餐食", isOn: $ai.allowsPhotoAI).disabled(!ai.canUsePhotoAI)
            DisclosureGroup("查看发送范围与自动分析规则") {
                Text("需要先开启本机照片识别并同意网络 AI 分析；日终分析最多发送 4 张照片给当前模型，估算会标出不确定性。照片不会发送到账号服务器。").font(.callout)
                Text("授权并配置后，新记录在安静 45 秒后自动更新今日理解，最短间隔 5 分钟。").font(.callout)
            }
        }
        if let error = ai.errorMessage { Section { Text(error).font(.callout).foregroundStyle(theme.warning) } }
    }
    private func focusedSettingsFieldDone() { focusedField = nil }
}


private struct IPhonePhotoAnalysisSettings: View {
    @Environment(\.riverTheme) private var theme
    @ObservedObject var photos: IPhonePhotoAnalyzer

    var body: some View {
        Toggle("在本机整理最近照片线索", isOn: Binding(
            get: { photos.isEnabled },
            set: { enabled in Task { await photos.setEnabled(enabled) } }
        ))
        Text("只读取你在系统照片权限中允许的照片，最近 7 天内最多整理 160 张。Vision 在设备上识别场景标签；照片原图不会写入 River Diary 数据库。")
            .font(.caption)
            .foregroundStyle(theme.secondaryInk)
        LabeledContent("状态", value: photos.status)
        if let error = photos.errorMessage {
            Text(error).font(.caption).foregroundStyle(theme.warning)
        }
        if photos.isScanning { ProgressView("正在本机整理照片线索…") }
    }
}

private struct IPhoneMotionSettings: View {
    @Environment(\.riverTheme) private var theme
    @ObservedObject var motion: IPhoneMotionCollector

    var body: some View {
        Toggle("识别步行、骑行和乘车", isOn: Binding(
            get: { motion.isEnabled },
            set: { motion.setEnabled($0) }
        ))
        Text("系统运动识别用于标注步行、骑行或车辆移动。它不能判断是不是网约车或共享单车；信息不足时会显示“乘车”或“骑行”。")
            .font(.caption)
            .foregroundStyle(theme.secondaryInk)
        LabeledContent("状态", value: motion.status)
    }
}
