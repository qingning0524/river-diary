import RiverDiaryCore
import SwiftUI

struct MacAccountLoginView: View {
    /// 本机已有日记（正式库或旧版状态）时，登录页要如实说明，避免用户以为数据丢了。
    var showsLocalDataNotice = false
    /// 从设置页以 sheet 打开时需要显式关闭；作为根登录页时不显示。
    var allowsDismiss = false

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: RiverAccountSessionStore
    @State private var email = ""
    @State private var code = ""
    @State private var challengeID: String?
    @State private var verifyRequestID = UUID().uuidString
    @State private var accepted = false
    @State private var errorMessage: String?
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            if allowsDismiss {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.secondaryInk)
                            .frame(width: 30, height: 30)
                            .background(Color.editor, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭账号绑定")
                }
                .padding(.top, 18)
                .padding(.trailing, 22)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "water.waves")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 7) {
                    Text("欢迎来到 River Diary")
                        .font(AppTypography.pageTitle())
                        .foregroundStyle(Color.ink)
                    Text("账号用于云副本与设备管理；不绑定也能继续写日记。绑定后这台设备上的本机资料会归当前账号。")
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.secondaryInk)
                    if showsLocalDataNotice {
                        Label(
                            "这台 Mac 上已有本机日记。登录后会继续使用；退出登录期间不会读取或改动它。",
                            systemImage: "externaldrive.fill.badge.checkmark"
                        )
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.secondaryInk)
                        .labelStyle(.titleAndIcon)
                        .padding(.top, 2)
                    }
                }

                RiverPanel {
                    VStack(alignment: .leading, spacing: 13) {
                        TextField("邮箱地址", text: $email)
                            .textContentType(.emailAddress)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("account.email")

                        if challengeID != nil {
                            TextField("邮件中的 8 位验证码", text: $code)
                                .textContentType(.oneTimeCode)
                                .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("account.code")
                                .onChange(of: code) { _, _ in verifyRequestID = UUID().uuidString }
                        }

                        Toggle("我已阅读并同意账号服务说明与隐私说明", isOn: $accepted)
                            .font(.footnote)
                            .accessibilityIdentifier("account.acceptTerms")
                        DisclosureGroup("账号服务与隐私说明") {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("账号服务保存你验证过的邮箱、设备标识、登录会话和同意记录，用于账号登录、安全管理与跨设备账号识别。")
                                Text("日记正文、位置记录和健康数据不会通过此账号接口上传。验证码用于邮箱验证；高级权益兑换状态保存在服务器账号中。")
                                Text("你可以在设置中退出账号，或在登录状态下删除账号。删除会撤销服务器会话和云副本；本机日记不会删除。")
                            }
                            .font(.footnote)
                            .foregroundStyle(Color.secondaryInk)
                            .padding(.vertical, 7)
                        }

                        if let notice { Text(notice).font(.footnote).foregroundStyle(Color.secondaryInk) }
                        if let errorMessage = errorMessage ?? account.lastError {
                            Text(errorMessage).font(AppTypography.secondary()).foregroundStyle(AppTheme.error)
                        }

                        if challengeID == nil {
                            Button {
                                Task { await requestCode() }
                            } label: {
                                if account.isBusy { ProgressView() }
                                else { Text("发送邮箱验证码") }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(account.isBusy || !email.contains("@"))
                            .accessibilityIdentifier("account.sendCode")
                        } else {
                            Button {
                                Task { await verifyCode() }
                            } label: {
                                if account.isBusy { ProgressView() }
                                else { Text("注册 / 登录") }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(account.isBusy || code.count != 8 || !accepted)
                            .accessibilityIdentifier("account.verifyCode")
                            Button("更换邮箱或重新获取验证码") {
                                challengeID = nil
                                code = ""
                                verifyRequestID = UUID().uuidString
                                errorMessage = nil
                                notice = nil
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("验证码将发送至该邮箱；使用尚未注册的邮箱验证后会创建账号。")
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryInk)
            }
            .frame(width: 470)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.workspace)
    }

    @MainActor private func requestCode() async {
        errorMessage = nil
        notice = nil
        do {
            challengeID = try await account.requestEmailCode(email)
            verifyRequestID = UUID().uuidString
            notice = "验证码已发送，请查收件箱和垃圾邮件；10 分钟内有效。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func verifyCode() async {
        guard let challengeID else { return }
        errorMessage = nil
        do {
            try await account.verifyEmailCode(challengeID: challengeID, code: code, email: email, acceptTerms: accepted, idempotencyKey: verifyRequestID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct MacAccountSettingsView: View {
    @EnvironmentObject private var account: RiverAccountSessionStore
    @EnvironmentObject private var store: DiaryStore
    @State private var activationCode = ""
    @State private var redeemRequestID = UUID().uuidString
    @State private var message: String?
    @State private var showsSignOutConfirmation = false
    @State private var showsLogin = false
    @State private var showsBindConfirmation = false
    @State private var showsDeletion = false
    @State private var errorMessage: String?

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "River Diary 账号", detail: "管理邮箱登录会话，并兑换账号高级权益。") {
                RiverPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        if let email = account.accountEmail {
                            RiverValueRow(title: "登录账号", value: email)
                        } else {
                            Text("当前是本机模式。绑定账号后可使用云副本与设备管理；不绑定也能继续写日记。")
                                .foregroundStyle(Color.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("绑定 River Diary 账号") {
                                if hasLocalData { showsBindConfirmation = true } else { showsLogin = true }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("account.bind")
                        }

                        if account.hasPremiumEntitlement {
                            let entitlement = account.entitlements.first(where: { $0.product_code == "riverdiary_premium" })
                            RiverValueRow(title: "高级权益", value: entitlement?.permanent == true ? "永久有效" : "有效至 \(entitlement?.expires_at.map(Self.displayDate) ?? "—")")
                        } else {
                            RiverValueRow(title: "高级权益", value: "未激活")
                        }

                        TextField("输入激活 / 兑换码", text: $activationCode)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("account.activationCode")
                            .onChange(of: activationCode) { _, _ in redeemRequestID = UUID().uuidString }

                        HStack {
                            Button(account.isBusy ? "正在兑换…" : "兑换激活码") {
                                Task { await redeem() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(account.isBusy || activationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("account.redeem")

                            Button("刷新权益状态") {
                                Task {
                                    do {
                                        try await account.refreshEntitlements()
                                        errorMessage = nil
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            }
                        }

                        if let message { Text(message).font(.footnote).foregroundStyle(AppTheme.accent) }
                        if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }

                        HStack {
                            Button("退出账号", role: .destructive) {
                                showsSignOutConfirmation = true
                            }
                            Button("删除账号…") { showsDeletion = true }
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("account.delete")
                        }
                        .confirmationDialog("要退出这个账号吗？", isPresented: $showsSignOutConfirmation, titleVisibility: .visible) {
                            Button("退出账号", role: .destructive) {
                                Task { await account.signOut() }
                            }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("退出后账号能力停止，本机日记与自动记录继续；重新登录后恢复账号功能。")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task {
            guard account.isSignedIn else { return }
            try? await account.refreshEntitlements()
        }
        .sheet(isPresented: $showsLogin) {
            MacAccountLoginView(showsLocalDataNotice: true, allowsDismiss: true)
                .environmentObject(account)
                .frame(minWidth: 620, minHeight: 620)
        }
        .sheet(isPresented: $showsDeletion) {
            MacAccountDeletionView()
                .environmentObject(account)
                .frame(width: 520)
        }
        .confirmationDialog("绑定后，本机已有的日记会归当前账号", isPresented: $showsBindConfirmation, titleVisibility: .visible) {
            Button("继续绑定") { showsLogin = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这台 Mac 已有本机日记或快记。绑定成功后，本机资料归当前账号；换另一个账号登录会被拒绝。未绑定时数据仍在本机。")
        }
    }

    private var hasLocalData: Bool {
        !store.entries.isEmpty || !store.quickCaptures.isEmpty || store.hasLocalChanges
    }

    @MainActor private func redeem() async {
        message = nil
        errorMessage = nil
        do {
            let receipt = try await account.redeem(code: activationCode, idempotencyKey: redeemRequestID)
            message = receipt.permanent ? "兑换成功：高级权益已永久生效。" : "兑换成功：高级权益有效至 \(receipt.expires_at.map(Self.displayDate) ?? "—")。"
            activationCode = ""
            redeemRequestID = UUID().uuidString
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func displayDate(_ value: String) -> String {
        String(value.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}

private struct MacAccountDeletionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: RiverAccountSessionStore
    @State private var challengeID: String?
    @State private var code = ""
    @State private var notice: String?
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var deletedJobID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("删除账号").font(AppTypography.sheetTitle())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭删除账号")
            }
            Text("这会删除服务器上的账号、会话和云副本，无法撤销。本机日记不会被删除；删除后本机资料仍属于该已删除账号，不能直接换绑另一个账号，请先导出。")
                .font(AppTypography.secondary())
                .foregroundStyle(Color.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            if let deletedJobID {
                Text("账号删除请求已提交（作业 \(deletedJobID)）。本机日记仍在；请保留恢复码，稍后可查看删除状态。")
                    .font(AppTypography.secondary())
                    .foregroundStyle(Color.green)
                Button("关闭") { dismiss() }
                    .buttonStyle(.borderedProminent)
            } else if challengeID == nil {
                Button(isWorking ? "正在发送…" : "发送邮箱验证码") {
                    Task {
                        isWorking = true
                        errorMessage = nil
                        do {
                            challengeID = try await account.startDeletionReauth()
                            notice = "验证码已发送到账号邮箱（8 位数字）。"
                        } catch {
                            errorMessage = UserFacingError.message(for: error)
                        }
                        isWorking = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
                .accessibilityIdentifier("account.delete.sendCode")
            } else {
                if let notice { Text(notice).font(AppTypography.micro()).foregroundStyle(Color.secondaryInk) }
                TextField("8 位邮箱验证码", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("account.delete.code")
                Button(isWorking ? "正在删除…" : "确认删除账号") {
                    Task {
                        isWorking = true
                        errorMessage = nil
                        do {
                            let token = try await account.verifyDeletionReauth(challengeID: challengeID ?? "", code: code)
                            let receipt = try await account.deleteAccount(reauthToken: token)
                            deletedJobID = receipt.job_id
                        } catch {
                            errorMessage = UserFacingError.message(for: error)
                        }
                        isWorking = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isWorking || code.count != 8)
                .accessibilityIdentifier("account.delete.confirm")
            }
            if let errorMessage { Text(errorMessage).font(AppTypography.micro()).foregroundStyle(.red) }
        }
        .padding(24)
    }
}
