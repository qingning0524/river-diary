import RiverDiaryCore
import SwiftUI

struct RiverPasswordRecoveryView: View {
    @Environment(\.riverTheme) private var theme
    @EnvironmentObject private var account: RiverAccountSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var email: String
    @State private var code = ""
    @State private var newPassword = ""
    @State private var repeatedPassword = ""
    @State private var challengeID: String?
    @State private var requestID = UUID().uuidString
    @State private var error: String?
    @State private var notice: String?
    @State private var resendAfter: Date?
    @FocusState private var focused: Field?
    private enum Field { case email, code, password, repeated }
    var isSetup = false
    init(initialEmail: String, isSetup: Bool = false) {
        _email = State(initialValue: initialEmail); self.isSetup = isSetup
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--riverdiary-qa-password-reset-preview") {
            _challengeID = State(initialValue: "650e8400-e29b-41d4-a716-446655440298")
        }
        #endif
    }
    private var isCodePreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--riverdiary-qa-password-reset-preview")
        #else
        false
        #endif
    }
    private var normalizedPassword: String { newPassword.precomposedStringWithCanonicalMapping }
    private var validPassword: Bool { (15...128).contains(normalizedPassword.unicodeScalars.count) && normalizedPassword.utf8.count <= 512 && !normalizedPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "lock.rotation").font(.system(size: 28, weight: .light)).foregroundStyle(theme.accentText).padding(.top, 12)
                    Text(isSetup ? "给账号设置密码" : "重新回到你的 River").font(theme.titleFont).foregroundStyle(theme.ink)
                    Text(challengeID == nil ? "先验证已注册的邮箱，再设置新的登录密码。" : "验证码只用于这次设置或重置密码。").font(theme.textFont(15)).foregroundStyle(theme.secondaryInk).fixedSize(horizontal: false, vertical: true)
                    fieldGroup("已注册的邮箱") {
                        TextField("邮箱地址", text: $email).keyboardType(.emailAddress).textContentType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused, equals: .email).disabled(challengeID != nil || account.isBusy).accessibilityIdentifier("account.password.reset.email")
                    }
                    if challengeID != nil {
                        fieldGroup("8 位邮箱验证码") {
                            TextField("输入验证码", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).focused($focused, equals: .code).accessibilityIdentifier("account.password.reset.code").onChange(of: code) { _, value in code = String(value.filter { "0123456789".contains($0) }.prefix(8)); requestID = UUID().uuidString }
                        }
                        fieldGroup("新登录密码") { SecureField("15–128 个字符，可使用长短语", text: $newPassword).textContentType(isCodePreview ? .none : .newPassword).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused, equals: .password).accessibilityIdentifier("account.password.reset.new") }
                        fieldGroup("再次输入新密码") { SecureField("确认新密码", text: $repeatedPassword).textContentType(isCodePreview ? .none : .newPassword).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused, equals: .repeated).accessibilityIdentifier("account.password.reset.confirm") }
                        if !newPassword.isEmpty && !validPassword { Text("请使用 15–128 个字符，空格也会保留。").font(theme.textFont(12)).foregroundStyle(theme.accentText).accessibilityIdentifier("account.password.reset.policy") }
                        if !repeatedPassword.isEmpty && normalizedPassword != repeatedPassword.precomposedStringWithCanonicalMapping { Text("两次输入的密码还不一致。").font(theme.textFont(12)).foregroundStyle(theme.accentText).accessibilityIdentifier("account.password.reset.mismatch") }
                        Text("保存后，原密码及其他设备上的旧会话会失效。").font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
                        HStack {
                            Button("更换邮箱") { challengeID = nil; code = ""; newPassword = ""; repeatedPassword = ""; error = nil; notice = nil; focused = .email }.font(theme.textFont(13)).frame(minHeight: 44)
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let remaining = max(0, Int(ceil((resendAfter ?? .distantPast).timeIntervalSince(context.date))))
                                Button(remaining > 0 ? "\(remaining)s 后可重发" : "重新获取验证码") { Task { await request() } }.font(theme.textFont(13)).frame(minHeight: 44).disabled(remaining > 0 || account.isBusy)
                            }
                        }
                    }
                    if let notice { Text(notice).font(theme.textFont(13)).foregroundStyle(theme.secondaryInk) }
                    if let error { Label(error, systemImage: "exclamationmark.circle").font(theme.textFont(13)).foregroundStyle(.red).accessibilityIdentifier("account.password.reset.error") }
                    Button { focused = nil; Task { if challengeID == nil { await request() } else { await complete() } } } label: {
                        HStack { if account.isBusy { ProgressView().tint(theme.palette.onAccent) }; Text(account.isBusy ? "正在处理…" : challengeID == nil ? "获取验证邮件" : "保存新密码").font(theme.textFont(16, weight: .medium)) }.foregroundStyle(enabled ? theme.palette.onAccent : theme.secondaryInk).frame(maxWidth: .infinity, minHeight: 54).background(enabled ? theme.accent : theme.raisedSurface, in: RoundedRectangle(cornerRadius: 15))
                    }.buttonStyle(.plain).disabled(!enabled).accessibilityIdentifier("account.password.reset.submit")
                    Text("尚未注册？请先返回登录页，用验证码创建账号。").font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk).padding(.bottom, 20)
                }.padding(.horizontal, 24)
            }.background(theme.canvas).scrollDismissesKeyboard(.interactively)
                .navigationTitle(isSetup ? "设置登录密码" : "忘记密码").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }; ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focused = nil } } }
                .onChange(of: newPassword) { _, _ in error = nil; requestID = UUID().uuidString }
                .onChange(of: repeatedPassword) { _, _ in error = nil; requestID = UUID().uuidString }
        }.tint(theme.accentText).presentationDetents([.large])
    }
    private var enabled: Bool { !isCodePreview && !account.isBusy && (challengeID == nil ? email.contains("@") && email.count <= 320 : code.count == 8 && validPassword && normalizedPassword == repeatedPassword.precomposedStringWithCanonicalMapping) }
    private func fieldGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk); content().font(theme.textFont(16)).padding(.horizontal, 16).frame(minHeight: 54).background(theme.surface, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.separator, lineWidth: 0.5)) }
    }
    @MainActor private func request() async {
        guard !isCodePreview else { return }
        error = nil
        do { challengeID = try await account.requestPasswordReset(email); code = ""; notice = "验证邮件已请求。若该邮箱已注册且可接收邮件，请检查收件箱和垃圾邮件。"; resendAfter = .now.addingTimeInterval(60); requestID = UUID().uuidString; focused = .code }
        catch { self.error = error.localizedDescription }
    }
    @MainActor private func complete() async {
        guard let challengeID, enabled else { return }
        error = nil
        do { try await account.resetPassword(email: email, challengeID: challengeID, code: code, newPassword: newPassword, idempotencyKey: requestID); newPassword = ""; repeatedPassword = ""; code = ""; dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
