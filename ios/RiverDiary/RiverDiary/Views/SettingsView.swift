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
    @AppStorage("backup.lastExportAt") private var lastExportAt: Double = 0
    @State private var diagnosticDocument: RiverDiagnosticsDocument?
    @State private var showsDiagnosticExport = false
    @State private var readableDiaryDocument: ReadableDiaryDocument?
    @State private var showsReadableDiaryExport = false
    @State private var readableDiaryMessage: String?
    @State private var showsJournal = false
    @State private var pendingJournalEditDate: Date?
    @State private var journalPresentation: RiverJournalPresentation?
    @State private var journalFeedback: RiverFeedback?
    @State private var showsInsights = false
    @State private var devicePendingRetirement: RiverDeviceID?
    @FocusState private var focusedSettingsField: SettingsInputField?
    @AppStorage("river.developerMode.enabled") private var developerModeEnabled = false
    @State private var cloudMeta: RiverCloudMirrorMeta?
    @State private var cloudPassphrase = ""
    @State private var cloudConfirmation = ""
    @State private var cloudIncludeHealth = false
    @State private var cloudPreview: MemoryMirrorArchive?
    @State private var cloudStatus = ""
    @State private var cloudStatusIsError = false
    @State private var cloudBusy = false
    @State private var showsCloudDeleteConfirmation = false
    @State private var showsCloudHealthConfirmation = false
    @State private var hasLoadedCloud = false

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
                case .success(let url):
                    lastExportAt = Date().timeIntervalSince1970
                    node.setBackupMessage("加密备份已导出到 \(url.lastPathComponent)")
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
            .fileExporter(
                isPresented: $showsReadableDiaryExport,
                document: readableDiaryDocument,
                contentType: .json,
                defaultFilename: "RiverDiary-Web-\(Date.now.formatted(.iso8601.year().month().day())).json"
            ) { result in
                switch result {
                case .success(let url): readableDiaryMessage = "网页副本已导出到 \(url.lastPathComponent)"
                case .failure(let error): readableDiaryMessage = "网页副本导出失败：\(error.localizedDescription)"
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
                    NavigationLink { cloudPage } label: { settingRow("云空间", value: cloudMeta?.exists == true ? "加密副本 v\(cloudMeta?.revision ?? 1)" : "端到端加密副本", symbol: "cloud") }
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
    private var aboutPage: some View {
        settingsPage("关于 River") {
            Section {
                Text("River Diary").font(theme.titleFont)
                Text("生活归你，记录也归你。")
                Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
            }
            Section("日记") {
                Button("日记与过往记录") { showsJournal = true }
                Button("情绪与长期回顾") { showsInsights = true }
            }
            Section("法律与状态") {
                Link("隐私政策", destination: RiverLegalLinks.privacyPolicy)
                Link("服务条款", destination: RiverLegalLinks.terms)
                Link("服务状态", destination: RiverLegalLinks.serviceStatus)
                Link("安全联系", destination: RiverLegalLinks.securityContact)
            }
        }
    }

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
                    screenTimeRow
                    voiceMemoRow
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

                    Text("换机或重装前必须把这串恢复码保存到本机之外。只存在钥匙串里的密钥会随设备丢失；没有它，加密备份和同步对象都无法解密。")
                        .font(.footnote)
                        .foregroundStyle(theme.warning)
                    Button(showsSyncKey ? "隐藏恢复码" : "显示或创建恢复码") {
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
                        Button("复制恢复码") {
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
                    Text("两台设备选择同一个 iCloud Drive 文件夹，并导入同一恢复码。恢复码只保存在本机钥匙串，请自行离线保存；同步文件不包含明文密钥。")
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
    private var cloudPage: some View {
        settingsPage("云空间") {
            if !account.isSignedIn {
                Section("云空间") {
                    Text("登录账号后可以上传端到端加密的只读副本。账号只用来识别副本属于谁；口令和明文都不离开这台设备。")
                        .font(.footnote).foregroundStyle(theme.secondaryInk)
                    NavigationLink("去登录") { settingsPage("账户与权益") { Section { AccountSettingsCard() } } }
                }
            } else {
                Section("云端副本") {
                    if let cloudMeta, cloudMeta.exists {
                        LabeledContent("当前版本", value: "v\(cloudMeta.revision ?? 1)")
                        LabeledContent("密文大小", value: cloudByteText(cloudMeta.sizeBytes))
                        LabeledContent("内容摘要", value: "\(cloudMeta.summary?.entries ?? 0) 段 · \(cloudMeta.summary?.days ?? 0) 天")
                        LabeledContent("健康数据", value: cloudMeta.summary?.includesHealth == true ? "已包含（上传端已同意）" : "未包含")
                        LabeledContent("最近更新", value: cloudFormat(cloudMeta.updatedAt))
                    } else {
                        Text("云空间还没有副本。第一次上传会创建 v1；之后每次更新都会递增版本。")
                            .font(.footnote).foregroundStyle(theme.secondaryInk)
                    }
                    Button("刷新状态") { Task { await refreshCloud() } }.disabled(cloudBusy)
                    if cloudMeta?.exists == true {
                        Button("删除云副本", role: .destructive) { showsCloudDeleteConfirmation = true }.disabled(cloudBusy)
                    }
                }
                Section(cloudMeta?.exists == true ? "更新云副本" : "上传到云空间") {
                    SecureField("云端口令 · 至少 12 个字符", text: $cloudPassphrase)
                        .textContentType(.newPassword)
                    SecureField("再次输入口令", text: $cloudConfirmation)
                        .textContentType(.newPassword)
                    Toggle("本次包含健康摘要（睡眠、步数、训练）", isOn: $cloudIncludeHealth)
                    Text("默认关闭。开启后本次上传会包含最近一次睡眠与活动摘要；服务器仍然只看到密文。关闭时健康段落会在加密前被剔除。")
                        .font(.footnote).foregroundStyle(theme.secondaryInk)
                    Button(cloudMeta?.exists == true ? "加密并更新" : "加密并上传") { Task { await uploadCloud() } }
                        .disabled(cloudBusy || cloudPassphrase.count < CloudMirrorCrypto.minPassphraseCharacters || cloudPassphrase != cloudConfirmation)
                }
                Section("从云空间恢复预览") {
                    SecureField("云端口令", text: $cloudPassphrase)
                        .textContentType(.password)
                    Button("下载并解密") { Task { await downloadCloud() } }
                        .disabled(cloudBusy || cloudMeta?.exists != true || cloudPassphrase.count < CloudMirrorCrypto.minPassphraseCharacters)
                    if let cloudPreview {
                        Text("只读预览 · \(cloudPreview.entries.count) 段日记 · \(cloudPreview.contexts.count) 个设备日上下文")
                            .font(.footnote).foregroundStyle(theme.secondaryInk)
                        ForEach(Array(cloudPreview.entries.suffix(3).reversed()), id: \.id) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(.subheadline)
                                Text("\(String(entry.occurredAt.prefix(10))) · \(entry.body.prefix(80))")
                                    .font(.caption).foregroundStyle(theme.secondaryInk).lineLimit(2)
                            }
                        }
                        Text("只读预览，不会覆盖本机日记。").font(.caption).foregroundStyle(theme.secondaryInk)
                    }
                }
                if !cloudStatus.isEmpty {
                    Section {
                        Text(cloudStatus).font(.footnote).foregroundStyle(cloudStatusIsError ? theme.danger : theme.secondaryInk)
                    }
                }
            }
            Section("边界") {
                Text("PBKDF2-SHA-256（600,000 次）派生密钥，AES-GCM-256 加密；盐和 IV 随密文保存，口令不离开本机。")
                    .font(.footnote).foregroundStyle(theme.secondaryInk)
                Text("云空间是手动快照，不会自动同步；删除云副本不会删除本机日记，注销账号会一并删除云副本。")
                    .font(.footnote).foregroundStyle(theme.secondaryInk)
            }
        }
        .task {
            guard account.isSignedIn, !hasLoadedCloud else { return }
            hasLoadedCloud = true
            await refreshCloud()
        }
        .confirmationDialog("删除云空间里的加密副本？", isPresented: $showsCloudDeleteConfirmation, titleVisibility: .visible) {
            Button("删除云副本", role: .destructive) { Task { await deleteCloud() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除服务器上的密文与摘要，不影响本机日记。")
        }
        .confirmationDialog("确认把健康摘要放进本次云副本？", isPresented: $showsCloudHealthConfirmation, titleVisibility: .visible) {
            Button("包含健康数据并上传", role: .destructive) { Task { await performCloudUpload() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("睡眠、步数和训练摘要会先在本机加密再上传。服务器仍然只看到密文，但拿到口令的人可以看到这些摘要；关闭开关后再上传即可撤回。")
        }
    }

    private func refreshCloud() async {
        guard account.isSignedIn else { return }
        cloudBusy = true
        defer { cloudBusy = false }
        do {
            cloudMeta = try await account.cloudMirrorMeta()
            if cloudMeta?.exists != true { cloudPreview = nil }
            setCloudStatus(cloudMeta?.exists == true ? "已读取云空间状态。" : "云空间还没有副本。", error: false)
        } catch {
            setCloudStatus(cloudMessage(error), error: true)
        }
    }

    private func uploadCloud() async {
        guard !cloudBusy, cloudPassphrase == cloudConfirmation else { return }
        if cloudIncludeHealth {
            showsCloudHealthConfirmation = true
            return
        }
        await performCloudUpload()
    }

    private func performCloudUpload() async {
        guard !cloudBusy else { return }
        cloudBusy = true
        defer { cloudBusy = false }
        do {
            var contexts = node.dayContextSnapshotsForWeb()
            let alreadyHasHealth = contexts.contains { context in
                context.sections.contains { MemoryMirrorArchive.healthSectionKinds.contains($0.kind) }
            }
            if cloudIncludeHealth, !alreadyHasHealth, let healthContext = cloudHealthContext() {
                contexts.append(healthContext)
            }
            let data = try store.webMirrorData(contexts: contexts)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let archive = try decoder.decode(MemoryMirrorArchive.self, from: data)
            let envelope = try CloudMirrorCrypto.buildEnvelope(
                archive: archive, passphrase: cloudPassphrase, includeHealth: cloudIncludeHealth
            )
            let updated = try await account.uploadCloudMirror(
                envelope, replacing: cloudMeta?.exists == true ? cloudMeta?.revision : nil
            )
            cloudMeta = updated
            cloudPreview = nil
            setCloudStatus("已加密上传 v\(updated.revision ?? 1)。另一台设备输入同一口令即可下载。", error: false)
        } catch {
            setCloudStatus(cloudMessage(error), error: true)
        }
    }

    private func downloadCloud() async {
        guard !cloudBusy else { return }
        cloudBusy = true
        defer { cloudBusy = false }
        do {
            let envelope = try await account.downloadCloudMirror()
            cloudPreview = try CloudMirrorCrypto.decrypt(envelope, passphrase: cloudPassphrase)
            setCloudStatus("已在本机解密。下面是只读预览，没有写回本地日记。", error: false)
        } catch {
            setCloudStatus(cloudMessage(error), error: true)
        }
    }

    private func deleteCloud() async {
        guard !cloudBusy, let revision = cloudMeta?.revision else { return }
        cloudBusy = true
        defer { cloudBusy = false }
        do {
            try await account.deleteCloudMirror(revision: revision)
            cloudMeta = RiverCloudMirrorMeta(exists: false)
            cloudPreview = nil
            setCloudStatus("云副本已删除；本机日记没有改动。", error: false)
        } catch {
            setCloudStatus(cloudMessage(error), error: true)
        }
    }

    private func cloudHealthContext() -> DayContextSnapshot? {
        var sections: [DayContextSection] = []
        if let night = health.latestNight {
            sections.append(DayContextSection(
                kind: "health", title: "睡眠",
                summary: String(format: "%.1f 小时 · %@", night.totalHours,
                                night.date.formatted(date: .abbreviated, time: .omitted))
            ))
        }
        if let exercise = health.latestExerciseDay {
            sections.append(DayContextSection(
                kind: "workout", title: "活动",
                summary: String(format: "%.0f 步 · %.1f 公里 · %@", exercise.steps,
                                exercise.distanceKilometers,
                                exercise.date.formatted(date: .abbreviated, time: .omitted))
            ))
        }
        if let workout = health.workouts.first {
            sections.append(DayContextSection(
                kind: "workout", title: "体能训练",
                summary: "\(workout.activityName) · \(Int(workout.end.timeIntervalSince(workout.start) / 60)) 分钟"
            ))
        }
        if let mood = health.stateOfMind.first {
            sections.append(DayContextSection(kind: "stateOfMind", title: "心情", summary: mood.kindLabel))
        }
        guard !sections.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return DayContextSnapshot(
            deviceID: node.deviceID, deviceName: UIDevice.current.name,
            day: formatter.string(from: Date()), sections: sections
        )
    }

    private func setCloudStatus(_ text: String, error: Bool) {
        cloudStatus = text
        cloudStatusIsError = error
    }

    private func cloudMessage(_ error: Error) -> String {
        if let error = error as? CloudMirrorError { return error.errorDescription ?? "云副本处理失败。" }
        if let error = error as? RiverAccountAPIError {
            switch error.status {
            case 404: return "云空间还没有副本。"
            case 409: return "云空间已有副本，请刷新后再更新。"
            case 412: return "云空间已被另一台设备更新，请刷新后再试。"
            case 428: return "缺少版本前置条件，请刷新后再试。"
            default: return error.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private func cloudByteText(_ value: Int?) -> String {
        guard let value, value >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private func cloudFormat(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
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


                Section("网页控制台") {
                    Text("导出 river.memory-mirror 只读 JSON，在 user.flowriver.xyz 导入后只读查看。包含当前设备可读的日记与双端“设备上下文”；不含密钥、健康原库或完整浏览器 URL。")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryInk)
                    Button("导出网页可读 JSON") { exportReadableDiary() }
                        .disabled(store.entries.isEmpty)
                    if let message = readableDiaryMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(message.hasPrefix("网页副本导出失败") ? theme.danger : theme.secondaryInk)
                    }
                }

                Section("本地备份") {
                    Text("备份包含原始事件、用户决定和 Artifact，并使用同步密钥加密。重装后恢复需要保留或重新导入同一同步密钥。")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryInk)
                    if lastExportAt == 0 {
                        Text("还没有导出过加密备份。建议今天先导出一份，并把恢复码保存在本机之外。")
                            .font(.footnote)
                            .foregroundStyle(theme.warning)
                    } else {
                        let days = Int((Date().timeIntervalSince1970 - lastExportAt) / 86_400)
                        if days >= 7 {
                            Text("上次加密备份已是 \(days) 天前。换机或重装前，请再导出一份并确认恢复码可用。")
                                .font(.footnote)
                                .foregroundStyle(theme.warning)
                        }
                    }
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
                    Text("HealthKit 的睡眠、运动与心情摘要只在本机读取和展示，不写入跨设备事实库，也不进入加密同步。旧版本已写入的健康事件需在正式上架前做一次单独清理。")
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

    private func exportReadableDiary() {
        guard !store.entries.isEmpty else {
            readableDiaryMessage = "当前本机没有可导出的日记 JSON。"
            return
        }
        do {
            let encoded = try store.webMirrorData(contexts: node.dayContextSnapshotsForWeb())
            readableDiaryDocument = ReadableDiaryDocument(data: encoded)
            showsReadableDiaryExport = true
            readableDiaryMessage = nil
        } catch {
            readableDiaryMessage = "网页副本导出失败：\(error.localizedDescription)"
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
                Text("已读取 \(health.nights.count) 晚睡眠 · \(health.exerciseDays.count) 天运动 · \(health.workouts.count) 次训练 · \(health.stateOfMind.count) 条心情").font(.footnote).foregroundStyle(theme.secondaryInk)
                Button("刷新健康记录") { health.loadHealth() }.frame(minHeight: 44)
            } else {
                Button("连接 Apple 健康") { health.requestAuthorization() }.frame(minHeight: 44)
            }
        }
    }

    private var screenTimeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("屏幕使用时间", systemImage: "iphone.gen3.radiowaves.left.and.right")
                Spacer()
                if let minutes = todayScreenTimeMinutes {
                    Text("\(minutes) 分钟").font(.footnote).foregroundStyle(theme.secondaryInk)
                }
            }
            Text("iOS 不向第三方 App 开放屏幕使用时间的原始数据。用快捷指令在晚上记录你在“设置 → 屏幕使用时间”看到的总分钟数；事件只写本机。")
                .font(.footnote)
                .foregroundStyle(theme.secondaryInk)
            if let minutes = todayScreenTimeMinutes {
                Text("今天已记录 \(minutes / 60) 小时 \(minutes % 60) 分钟。重新运行会覆盖当天显示，不会相加。")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryInk)
            }
            Button("打开快捷指令") { openShortcutsApp() }
                .frame(minHeight: 44)
            DisclosureGroup("配置步骤") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. 打开“快捷指令” → “自动化” → “新建个人自动化” → “特定时间”，设为每天 22:00。")
                    Text("2. 添加“要求输入”，类型选数字，提示“今天屏幕使用时间（分钟）”。")
                    Text("3. 添加 River Diary 的“记录屏幕使用时间”操作，把输入作为分钟数。")
                    Text("4. 关闭“运行前询问”，选择立即运行。")
                    Text("也可以在“快捷指令”里手动运行，随时补记。")
                }
                .font(.footnote)
                .foregroundStyle(theme.secondaryInk)
                .padding(.vertical, 4)
            }
        }
    }

    private var voiceMemoRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("语音速记", systemImage: "mic")
            Text("用快捷指令的“听写文本”把口述转成文字，再调用 River Diary 的“记录语音速记”。只保存文字，不保存音频，也不需要麦克风权限。")
                .font(.footnote)
                .foregroundStyle(theme.secondaryInk)
            Button("打开快捷指令") { openShortcutsApp() }
                .frame(minHeight: 44)
        }
    }

    private var todayScreenTimeMinutes: Int? {
        guard let database = node.database else { return nil }
        return RiverScreenTimeRecorder.latestMinutes(in: database)
    }

    private func openShortcutsApp() {
        guard let url = URL(string: "shortcuts://") else { return }
        UIApplication.shared.open(url)
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
            Menu {
                Button("DeepSeek") {
                    ai.endpoint = "https://api.deepseek.com/chat/completions"
                    ai.model = "deepseek-chat"
                }
                Button("OpenAI 兼容") {
                    ai.endpoint = "https://api.openai.com/v1/chat/completions"
                    ai.model = "gpt-4o-mini"
                }
                Button("本机 Ollama") {
                    ai.endpoint = "http://127.0.0.1:11434/v1/chat/completions"
                    ai.model = "llama3.1"
                }
            } label: {
                Label("填入常用服务（仍可自定义）", systemImage: "wand.and.stars")
                    .font(.footnote)
            }
            .accessibilityIdentifier("river.ai.preset")
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


private struct ReadableDiaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
