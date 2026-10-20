import RiverDiaryCore
import SwiftUI

struct MacAccountLoginView: View {
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
            Spacer()
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "water.waves")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 7) {
                    Text("欢迎来到 River Diary")
                        .font(AppTypography.pageTitle())
                        .foregroundStyle(Color.ink)
                    Text("首次使用请用邮箱验证码创建账号或登录。你的日记仍保存在本机。")
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.secondaryInk)
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
                                Text("你可以在设置中退出账号。账号删除及身份解绑当前尚未开放。")
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
    @State private var activationCode = ""
    @State private var redeemRequestID = UUID().uuidString
    @State private var message: String?
    @State private var showsSignOutConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "River Diary 账号", detail: "管理邮箱登录会话，并兑换账号高级权益。") {
                RiverPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        if let email = account.accountEmail {
                            RiverValueRow(title: "登录账号", value: email)
                        } else {
                            Text("当前没有账号会话。")
                                .foregroundStyle(Color.secondaryInk)
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

                        Button("退出账号", role: .destructive) {
                            showsSignOutConfirmation = true
                        }
                        .confirmationDialog("要退出这个账号吗？", isPresented: $showsSignOutConfirmation, titleVisibility: .visible) {
                            Button("退出账号", role: .destructive) {
                                Task { await account.signOut() }
                            }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("退出后本机的自动采集与同步会暂停，重新登录后恢复。")
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
