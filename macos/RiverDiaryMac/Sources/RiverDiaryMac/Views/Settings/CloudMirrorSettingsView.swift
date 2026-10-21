import SwiftUI
import RiverDiaryCore

/// macOS 的最小云空间入口：本机导出 → 本机加密 → 上传；下载 → 本机解密 →
/// 只读预览。它不会把下载内容写回本地日记，也不会自动同步。
struct CloudMirrorSettingsView: View {
    @EnvironmentObject private var account: RiverAccountSessionStore
    @ObservedObject var store: DiaryStore
    @ObservedObject var ingestion: DataIngestionStore

    @State private var meta: RiverCloudMirrorMeta?
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var preview: MemoryMirrorArchive?
    @State private var status = ""
    @State private var statusIsError = false
    @State private var isBusy = false
    @State private var showsDeleteConfirmation = false
    @State private var hasLoaded = false

    var body: some View {
        SettingsPage {
            if !account.isSignedIn {
                signedOutCard
            } else {
                cloudCard
                uploadCard
                restoreCard
            }
            boundaryCard
        }
        .task(id: account.isSignedIn) {
            guard account.isSignedIn, !hasLoaded else { return }
            hasLoaded = true
            await refresh()
        }
        .confirmationDialog("删除云空间里的加密副本？", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button("删除云副本", role: .destructive) { Task { await deleteCloud() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除服务器上的这份密文和元数据，不影响本机日记。删除后其他设备无法再从云空间取回这份快照。")
        }
    }

    private var signedOutCard: some View {
        SettingsGroup(title: "云空间", detail: "登录后才会出现上传入口。云空间是手动快照，不是自动同步。") {
            RiverPanel {
                RiverPanelRow(title: "还没有登录账号", detail: "账号只用来识别这份云副本属于谁；加密和口令都在本机完成。", systemImage: "person.crop.circle") {
                    Button("去登录") {
                        NotificationCenter.default.post(
                            name: .riverSettingsNavigate, object: nil,
                            userInfo: ["category": SettingsCategory.account.rawValue]
                        )
                    }
                    .buttonStyle(.plain)
                    .smallAction()
                }
            }
        }
    }

    private var cloudCard: some View {
        SettingsGroup(title: "云空间", detail: "服务器只保存密文和“几段、几天、多大”这类摘要。它拿不到口令，也解不开正文。") {
            RiverPanel {
                if let meta, meta.exists {
                    RiverValueRow(title: "当前副本", value: "v\(meta.revision ?? 1)")
                    RiverValueRow(title: "密文大小", value: formatBytes(meta.sizeBytes))
                    RiverValueRow(title: "内容摘要", value: "\(meta.summary?.entries ?? 0) 段 · \(meta.summary?.days ?? 0) 天")
                    RiverValueRow(title: "健康数据", value: meta.summary?.includesHealth == true ? "已包含（上传端已同意）" : "未包含")
                    RiverValueRow(title: "最近更新", value: format(meta.updatedAt), showsDivider: false)
                } else {
                    RiverPanelRow(title: "云空间还没有副本", detail: "第一次上传会创建 v1；之后每次更新都会递增版本。", systemImage: "cloud", showsDivider: false)
                }
                HStack {
                    Button("刷新状态") { Task { await refresh() } }
                        .buttonStyle(.plain).smallAction().disabled(isBusy)
                    Spacer()
                    if meta?.exists == true {
                        Button("删除云副本", role: .destructive) { showsDeleteConfirmation = true }
                            .buttonStyle(.plain).smallAction().disabled(isBusy)
                    }
                }
                .padding(.top, 8)
                statusLine
            }
        }
    }

    private var uploadCard: some View {
        SettingsGroup(title: meta?.exists == true ? "更新云副本" : "上传到云空间", detail: "用同一口令在另一台设备打开。忘记口令时，服务端也无法恢复。") {
            RiverPanel {
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("云端口令 · 至少 12 个字符", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isBusy)
                    SecureField("再次输入口令", text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isBusy)
                    Text("Mac 端没有 HealthKit 数据；上传前会剔除从 iPhone 同步来的健康段落。若要主动包含健康摘要，请从 iPhone 的云空间入口上传。")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(meta?.exists == true ? "加密并更新" : "加密并上传") {
                            Task { await upload() }
                        }
                        .buttonStyle(.plain).smallAction()
                        .disabled(isBusy || passphrase.count < CloudMirrorCrypto.minPassphraseCharacters || passphrase != confirmation)
                        if isBusy { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    statusLine
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var restoreCard: some View {
        SettingsGroup(title: "从云空间恢复预览", detail: "下载、在本机解密，然后只读预览。不会覆盖这台 Mac 上的日记。") {
            RiverPanel {
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("云端口令", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isBusy)
                    HStack {
                        Button("下载并解密") { Task { await download() } }
                            .buttonStyle(.plain).smallAction()
                            .disabled(isBusy || meta?.exists != true || passphrase.count < CloudMirrorCrypto.minPassphraseCharacters)
                        if isBusy { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if let preview {
                        Divider()
                        Text("只读预览 · \(preview.entries.count) 段日记 · \(preview.contexts.count) 个设备日上下文")
                            .font(AppTypography.rowTitle())
                        ForEach(Array(preview.entries.suffix(3).reversed()), id: \.id) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(AppTypography.metadata()).foregroundStyle(Color.ink)
                                Text("\(String(entry.occurredAt.prefix(10))) · \(entry.body.prefix(90))")
                                    .font(AppTypography.metadata()).foregroundStyle(Color.secondaryInk)
                                    .lineLimit(2)
                            }
                        }
                        if preview.entries.count > 3 {
                            Text("仅显示最近 3 段；完整内容仍在云副本中，本轮不会写回本地。")
                                .font(AppTypography.metadata()).foregroundStyle(Color.secondaryInk)
                        }
                    }
                    statusLine
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var boundaryCard: some View {
        SettingsGroup(title: "边界", detail: nil) {
            RiverPanel {
                RiverPanelRow(title: "端到端加密", detail: "PBKDF2-SHA-256（600,000 次）派生密钥，AES-GCM-256 加密；盐和 IV 随密文保存，口令不离开本机。", systemImage: "lock.shield")
                RiverPanelRow(title: "手动快照", detail: "不会自动同步。本机更新后要再次上传；其他设备要重新下载。", systemImage: "hand.raised")
                RiverPanelRow(title: "删除只影响云端", detail: "删除云副本不会删除本机日记；注销账号会一并删除云副本。", systemImage: "trash", showsDivider: false)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if !status.isEmpty {
            Text(status)
                .font(AppTypography.metadata())
                .foregroundStyle(statusIsError ? Color.red : Color.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refresh() async {
        guard account.isSignedIn else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            meta = try await account.cloudMirrorMeta()
            if !(meta?.exists ?? false) { preview = nil }
            setStatus(meta?.exists == true ? "已读取云空间状态。" : "云空间还没有副本。", error: false)
        } catch {
            setStatus(message(for: error), error: true)
        }
    }

    private func upload() async {
        guard !isBusy else { return }
        guard passphrase == confirmation else { setStatus("两次输入的口令不一致。", error: true); return }
        isBusy = true
        defer { isBusy = false }
        do {
            let data = try store.webMirrorData(contexts: ingestion.dayContextSnapshotsForWeb())
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let archive = try decoder.decode(MemoryMirrorArchive.self, from: data)
            let envelope = try CloudMirrorCrypto.buildEnvelope(
                archive: archive, passphrase: passphrase, includeHealth: false
            )
            let updated = try await account.uploadCloudMirror(envelope, replacing: meta?.exists == true ? meta?.revision : nil)
            meta = updated
            preview = nil
            setStatus("已加密上传 v\(updated.revision ?? 1)。另一台设备输入同一口令即可下载。", error: false)
        } catch {
            setStatus(message(for: error), error: true)
        }
    }

    private func download() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let envelope = try await account.downloadCloudMirror()
            let archive = try CloudMirrorCrypto.decrypt(envelope, passphrase: passphrase)
            preview = archive
            setStatus("已在本机解密。下面是只读预览，没有写回本地日记。", error: false)
        } catch {
            setStatus(message(for: error), error: true)
        }
    }

    private func deleteCloud() async {
        guard !isBusy, let revision = meta?.revision else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await account.deleteCloudMirror(revision: revision)
            meta = RiverCloudMirrorMeta(exists: false)
            preview = nil
            setStatus("云副本已删除；本机日记没有改动。", error: false)
        } catch {
            setStatus(message(for: error), error: true)
        }
    }

    private func setStatus(_ text: String, error: Bool) {
        status = text
        statusIsError = error
    }

    private func message(for error: Error) -> String {
        if let error = error as? CloudMirrorError {
            return error.errorDescription ?? "云副本处理失败。"
        }
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

    private func formatBytes(_ value: Int?) -> String {
        guard let value, value >= 0 else { return "—" }
        if value < 1024 { return "\(value) B" }
        let units = ["KB", "MB", "GB"]
        var size = Double(value) / 1024
        var index = 0
        while size >= 1024, index < units.count - 1 { size /= 1024; index += 1 }
        return String(format: size >= 10 ? "%.0f %@" : "%.1f %@", size, units[index])
    }

    private func format(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}
