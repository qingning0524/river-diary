import RiverDiaryCore
import SwiftUI

struct AccountLoginView: View {
    /// 从设置页以 sheet 打开时显示关闭按钮；作为根登录页时不显示。
    var allowsDismiss = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.riverTheme) private var theme
    @EnvironmentObject private var account: RiverAccountSessionStore
    @EnvironmentObject private var themeStore: RiverThemeStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loginMethod: LoginMethod = .code
    @State private var password = ""
    @State private var passwordVisible = false
    @State private var showsRecovery = false
    private enum LoginMethod { case code, password }
    @State private var email = ""
    @State private var code = ""
    @State private var challengeID: String?
    @State private var verifyRequestID = UUID().uuidString
    @State private var accepted = false
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var showsTerms = false
    @State private var resendAfter: Date?
    @FocusState private var focused: LoginField?
    private enum LoginField { case email, code, password }

    private var emailReady: Bool {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return value.count <= 320 && parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".") && !value.contains(where: \.isWhitespace)
    }
    private var isCodePreview: Bool {
        #if DEBUG
        return Bundle.main.bundleIdentifier == "studio.riverdiary.ios.qa" && ProcessInfo.processInfo.arguments.contains("--riverdiary-qa-login-code-preview")
        #else
        return false
        #endif
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: focused == nil ? 24 : 20) {
                        brandBar
                        if focused == nil { welcome }
                        else { Text(challengeID == nil ? loginMethod == .password ? "密码登录" : "用邮箱开始" : "输入验证码").font(theme.titleFont).padding(.top, 8) }
                        loginForm
                        trustFooter
                        Spacer(minLength: 12)
                    }
                    .frame(maxWidth: 420, minHeight: max(0, geometry.size.height - 48), alignment: .top)
                    .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively)
                    .background(theme.canvas.ignoresSafeArea())
            }
            .background(theme.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focused = nil }.accessibilityIdentifier("account.keyboardDone") }
            }
        }
        .sheet(isPresented: $showsTerms) { termsSheet }
        .sheet(isPresented: $showsRecovery) { RiverPasswordRecoveryView(initialEmail: email) }
        .task {
            #if DEBUG
            if isCodePreview { email = "hello@example.com"; challengeID = "qa-visual-preview" }
            #endif
        }
    }
    private var brandBar: some View {
        HStack(spacing: 10) {
            RiverSystemSignature()
            Spacer()
            if allowsDismiss {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.secondaryInk)
                        .frame(width: 44, height: 44)
                        .background(theme.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭账号绑定")
            }
            Menu {
                ForEach(RiverThemeID.allCases) { id in
                    Button { themeStore.applyTheme(id) } label: {
                        Label(id.name, systemImage: themeStore.selectedThemeID == id ? "checkmark" : id.symbol)
                    }.accessibilityIdentifier("account.style.\(id.rawValue)")
                }
            } label: {
                Image(systemName: theme.id == .nightDashboard ? "moon" : "circle.lefthalf.filled")
                    .font(.system(size: 17, weight: .regular)).foregroundStyle(theme.secondaryInk)
                    .frame(width: 44, height: 44).contentShape(Circle())
            }.accessibilityLabel("选择登录页外观").accessibilityIdentifier("account.appearance")
        }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(challengeID == nil ? "河流日记 / RIVER DIARY" : "RIVER ID")
                .font(.system(.caption, design: .monospaced)).tracking(2)
                .foregroundStyle(theme.accentText)
            Text(challengeID == nil ? loginMethod == .password ? "回到你的\n记忆空间。" : "每一天，\n汇成你的记忆。" : "确认你的邮箱")
                .font(.custom("SongtiSC-Regular", size: challengeID == nil ? 38 : 30, relativeTo: .largeTitle))
                .lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(theme.ink).accessibilityIdentifier("account.login.title")
            Text(challengeID == nil ? "你的日常、足迹与理解，在同一个个人记忆系统里延续。" : "输入邮件中的 8 位验证码，进入你的 River。")
                .font(.body).lineSpacing(4).foregroundStyle(theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            if challengeID == nil && !typeSize.isAccessibilitySize {
                HStack(spacing: 0) {
                    brandCapability("记录", symbol: "square.and.pencil")
                    brandCapability("连接", symbol: "icloud")
                    brandCapability("理解", symbol: "water.waves")
                }
                .padding(.vertical, 16)
                .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 0.5) }
                .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 0.5) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
    }

    private func brandCapability(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(theme.accentText)
            Text(title).foregroundStyle(theme.ink)
        }
        .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            if challengeID == nil { loginMethodPicker }
            else if focused == nil { Text("输入验证码").font(theme.sectionFont).foregroundStyle(theme.ink) }
            if challengeID == nil {
                emailField
                if loginMethod == .password {
                    passwordField
                    HStack { Text("使用已设置密码的邮箱账号").font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk); Spacer(); Button("忘记密码？") { focused = nil; showsRecovery = true }.font(theme.textFont(12, relativeTo: .footnote)).frame(minHeight: 44).foregroundStyle(theme.accentText).accessibilityIdentifier("account.password.forgot") }
                } else {
                    Text("验证码登录，无需密码。首次验证会创建账号。").font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "envelope").font(.system(size: 16)).foregroundStyle(theme.accentText).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("收件邮箱").font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
                        Text(email).font(theme.textFont(15, weight: .medium)).foregroundStyle(theme.ink).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button("更换") { changeEmail() }.font(theme.textFont(13)).frame(minHeight: 44).foregroundStyle(theme.accentText).accessibilityIdentifier("account.changeEmail")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("8 位验证码").font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
                    TextField("请输入验证码", text: $code)
                        .font(.custom("Menlo-Regular", size: 23, relativeTo: .title2)).kerning(4)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode).focused($focused, equals: .code)
                        .padding(.horizontal, 16).frame(minHeight: 60)
                        .background(theme.raisedSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(focused == .code ? theme.accent.opacity(0.7) : theme.separator, lineWidth: focused == .code ? 1 : 0.5))
                        .accessibilityLabel("邮件中的 8 位验证码").accessibilityIdentifier("account.code")
                        .onChange(of: code) { _, value in
                            let clean = String(value.filter { "0123456789".contains($0) }.prefix(8)); if value != clean { code = clean }
                            verifyRequestID = UUID().uuidString; errorMessage = nil
                        }
                    HStack {
                        Text("10 分钟内有效").font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, Int(ceil((resendAfter ?? .distantPast).timeIntervalSince(context.date))))
                            Button(remaining > 0 ? "\(remaining)s 后重新获取" : "重新获取验证码") { Task { await requestCode() } }
                                .font(theme.textFont(12, relativeTo: .footnote)).frame(minHeight: 44).foregroundStyle(remaining > 0 ? theme.secondaryInk : theme.accentText)
                                .disabled(account.isBusy || remaining > 0 || isCodePreview).accessibilityIdentifier("account.resendCode")
                        }
                    }
                }
            }
            if let errorMessage = errorMessage ?? account.lastError {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill").font(theme.textFont(13)).foregroundStyle(theme.danger).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("account.error")
            } else if let notice {
                Text(notice).font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("account.notice")
            }
            consentRow
            Button {
                focused = nil
                Task { if challengeID != nil { await verifyCode() } else if loginMethod == .password { await signInWithPassword() } else { await requestCode() } }
            } label: {
                HStack(spacing: 10) {
                    if account.isBusy { ProgressView().tint(theme.palette.onAccent) }
                    Text(account.isBusy ? "正在处理…" : challengeID == nil ? loginMethod == .password ? "登录 River" : "获取验证码" : "进入我的 River").font(theme.textFont(16, weight: .medium))
                    if !account.isBusy { Image(systemName: "arrow.right").font(.system(size: 15, weight: .medium)) }
                }.foregroundStyle(primaryEnabled ? theme.palette.onAccent : theme.secondaryInk)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(primaryEnabled ? theme.accent : theme.raisedSurface, in: RoundedRectangle(cornerRadius: 15))
                    .contentShape(RoundedRectangle(cornerRadius: 15))
            }.buttonStyle(.plain).disabled(!primaryEnabled)
                .accessibilityLabel(challengeID == nil ? loginMethod == .password ? "密码登录" : "发送邮箱验证码" : "注册 / 登录")
                .accessibilityIdentifier(challengeID == nil ? loginMethod == .password ? "account.password.login" : "account.sendCode" : "account.verifyCode")
        }.padding(theme.id == .contemporaryJournal ? 0 : 22)
            .background(theme.id == .contemporaryJournal ? .clear : theme.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(theme.id == .contemporaryJournal ? .clear : theme.separator.opacity(0.7), lineWidth: 0.5))
    }
    private var primaryEnabled: Bool {
        !account.isBusy && !isCodePreview && (challengeID == nil ? emailReady && (loginMethod == .code || !password.isEmpty && password.utf8.count <= 512 && accepted) : code.count == 8 && accepted)
    }
    private var loginMethodPicker: some View {
        HStack(spacing: 4) {
            methodButton("验证码登录", method: .code, id: "account.method.code")
            methodButton("密码登录", method: .password, id: "account.method.password")
        }.padding(4).background(theme.raisedSurface, in: RoundedRectangle(cornerRadius: 13))
    }
    private func methodButton(_ title: String, method: LoginMethod, id: String) -> some View {
        Button {
            RiverHaptics.selection()
            loginMethod = method; focused = nil; errorMessage = nil; notice = nil; password = ""; passwordVisible = false; verifyRequestID = UUID().uuidString
        } label: { Text(title).font(theme.textFont(14, weight: loginMethod == method ? .medium : .regular)).foregroundStyle(loginMethod == method ? theme.accentText : theme.secondaryInk).frame(maxWidth: .infinity, minHeight: 44).background(loginMethod == method ? theme.surface : .clear, in: RoundedRectangle(cornerRadius: 10)) }
            .buttonStyle(.plain).accessibilityIdentifier(id).accessibilityAddTraits(loginMethod == method ? .isSelected : [])
    }
    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("登录密码").font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
            HStack(spacing: 10) {
                Image(systemName: "lock").font(.system(size: 17)).foregroundStyle(theme.secondaryInk)
                Group {
                    if passwordVisible { TextField("输入登录密码", text: $password) }
                    else { SecureField("输入登录密码", text: $password) }
                }.font(theme.textFont(16)).textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused, equals: .password).submitLabel(.go).accessibilityIdentifier("account.password")
                    .onSubmit { if primaryEnabled { focused = nil; Task { await signInWithPassword() } } }
                    .onChange(of: password) { _, _ in errorMessage = nil; verifyRequestID = UUID().uuidString }
                Button { passwordVisible.toggle() } label: { Image(systemName: passwordVisible ? "eye.slash" : "eye").font(.system(size: 17)).foregroundStyle(theme.secondaryInk).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel(passwordVisible ? "隐藏密码" : "显示密码").accessibilityIdentifier("account.password.visibility")
            }.padding(.leading, 16).padding(.trailing, 4).frame(minHeight: 54).background(theme.raisedSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(focused == .password ? theme.accent.opacity(0.7) : theme.separator, lineWidth: 0.5))
        }
    }
    @MainActor private func signInWithPassword() async {
        guard emailReady, !password.isEmpty, accepted, !account.isBusy, !isCodePreview else { return }
        errorMessage = nil
        do { try await account.loginWithPassword(email: email, password: password, idempotencyKey: verifyRequestID); password = "" }
        catch { errorMessage = error.localizedDescription }
    }
    private var emailField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("邮箱地址").font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
            HStack(spacing: 10) {
                Image(systemName: "envelope").font(.system(size: 17)).foregroundStyle(theme.secondaryInk)
                TextField("你的常用邮箱", text: $email)
                    .font(theme.textFont(16)).keyboardType(.emailAddress).textContentType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused, equals: .email)
                    .submitLabel(.continue).disabled(account.isBusy)
                    .accessibilityLabel("邮箱地址").accessibilityIdentifier("account.email")
                    .onSubmit { if emailReady { if loginMethod == .password { focused = .password } else { focused = nil; Task { await requestCode() } } } else { errorMessage = "请输入完整的邮箱地址。" } }
                    .onChange(of: email) { _, _ in errorMessage = nil }
            }.padding(.horizontal, 16).frame(minHeight: 54)
                .background(theme.raisedSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(focused == .email ? theme.accent.opacity(0.7) : theme.separator, lineWidth: focused == .email ? 1 : 0.5))
        }
    }
    private var consentRow: some View {
        HStack(alignment: .top, spacing: 4) {
            Button { accepted.toggle() } label: {
                Image(systemName: accepted ? "checkmark.circle.fill" : "circle").font(.system(size: 21, weight: .regular))
                    .foregroundStyle(accepted ? theme.accentText : theme.secondaryInk.opacity(0.75)).frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityIdentifier("account.acceptTerms")
                .accessibilityLabel("我已阅读并同意账号服务与隐私说明").accessibilityValue(accepted ? "已同意" : "未同意").accessibilityAddTraits(accepted ? .isSelected : [])
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 3) {
                    Text("我已阅读并同意").font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
                    termsButton
                }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("我已阅读并同意").font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
                    termsButton
                }
            }
            Spacer(minLength: 0)
        }
    }
    private var termsButton: some View {
        Button("账号服务与隐私说明") { showsTerms = true }
            .font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.accentText).frame(minHeight: 44, alignment: .leading)
            .multilineTextAlignment(.leading).accessibilityIdentifier("account.terms.open")
    }
    private var trustFooter: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "lock.shield").font(.system(size: 13)).padding(.top, 2)
            Text("River ID 连接你的身份。记忆先保存在本机，跨设备连接由你在设置中开启。").font(theme.textFont(12, relativeTo: .footnote)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(theme.secondaryInk).padding(.horizontal, theme.id == .contemporaryJournal ? 0 : 8)
    }
    private var termsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    policySection("账号服务", "账号服务保存你验证过的邮箱、设备标识、登录会话和同意记录，用于账号登录、安全管理与跨设备账号识别。首次使用邮箱验证后会创建账号。")
                    policySection("你的生活记录", "日记正文、位置记录和健康数据不会通过账号接口上传。跨设备复制与网络 AI 的资料使用由应用中的独立设置管理。")
                    policySection("权益与退出", "高级权益兑换状态保存在服务器账号中。你可以在设置中退出账号。账号删除及身份解绑当前尚未开放。")
                }.padding(24)
            }.background(theme.canvas).navigationTitle("账号服务与隐私说明").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showsTerms = false } } }
        }.tint(theme.accentText).presentationDetents([.large])
    }
    private func policySection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(theme.sectionFont).foregroundStyle(theme.ink); Text(body).font(theme.textFont(16)).lineSpacing(6).foregroundStyle(theme.secondaryInk) }
    }
    private func changeEmail() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { challengeID = nil; code = "" }
        verifyRequestID = UUID().uuidString; notice = nil; errorMessage = nil; resendAfter = nil; focused = .email
    }
    @MainActor private func requestCode() async {
        guard emailReady, !account.isBusy, !isCodePreview else { return }
        errorMessage = nil; notice = nil
        do {
            email = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let challenge = try await account.requestEmailCode(email)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { challengeID = challenge; code = "" }
            verifyRequestID = UUID().uuidString; resendAfter = .now.addingTimeInterval(60)
            notice = "验证码已请求。若未收到，请检查垃圾邮件。"; RiverHaptics.success(); focused = .code
        } catch { errorMessage = error.localizedDescription }
    }
    @MainActor private func verifyCode() async {
        guard let challengeID, code.count == 8, accepted, !account.isBusy, !isCodePreview else { return }
        errorMessage = nil
        do { try await account.verifyEmailCode(challengeID: challengeID, code: code, email: email, acceptTerms: accepted, idempotencyKey: verifyRequestID) }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct RiverLoginMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.72, y: rect.height * 0.10))
        path.addCurve(to: CGPoint(x: rect.width * 0.29, y: rect.height * 0.89), control1: CGPoint(x: rect.width * 0.05, y: rect.height * 0.25), control2: CGPoint(x: rect.width * 0.95, y: rect.height * 0.67))
        path.move(to: CGPoint(x: rect.width * 0.90, y: rect.height * 0.18))
        path.addCurve(to: CGPoint(x: rect.width * 0.44, y: rect.height * 0.96), control1: CGPoint(x: rect.width * 0.23, y: rect.height * 0.34), control2: CGPoint(x: rect.width * 1.05, y: rect.height * 0.74))
        return path
    }
}

struct AccountSettingsCard: View {
    @Environment(\.riverTheme) private var theme
    @EnvironmentObject private var account: RiverAccountSessionStore
    @EnvironmentObject private var store: DiaryStore
    @EnvironmentObject private var node: RiverNodeStore
    @State private var showsPasswordSetup = false
    @State private var showsLogin = false
    @State private var showsBindConfirmation = false
    @State private var configuredPassword: Bool?
    @State private var activationCode = ""
    @State private var redeemRequestID = UUID().uuidString
    @State private var message: String?
    @State private var errorMessage: String?

    private var hasLocalData: Bool {
        !store.entries.isEmpty || node.eventCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                RiverBrandMark().stroke(theme.accentText, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 36, height: 42).padding(12)
                    .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("RIVER ID").font(.system(.caption, design: .monospaced)).tracking(2).foregroundStyle(theme.accentText)
                    Text(account.isSignedIn ? "你的个人记忆身份" : "连接你的 River")
                        .font(theme.sectionFont).foregroundStyle(theme.ink)
                    Text(account.isSignedIn ? "账号已登录" : "当前没有账号会话")
                        .font(.footnote).foregroundStyle(theme.secondaryInk)
                }
            }
            Rectangle().fill(theme.separator).frame(height: 0.5)
            if let email = account.accountEmail {
                LabeledContent("登录账号", value: email)
            } else {
                Text(account.isSignedIn ? "账号资料暂未加载，可刷新权益状态。" : "当前是本机模式。绑定账号后可使用官方 AI 额度、云副本与设备管理；不绑定也能继续写日记。")
                    .foregroundStyle(theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button("绑定 River Diary 账号") {
                    if hasLocalData { showsBindConfirmation = true } else { showsLogin = true }
                }
                .riverPrimary()
                .accessibilityIdentifier("account.bind")
            }

            if account.isSignedIn {
            Button { showsPasswordSetup = true } label: { HStack { Label(configuredPassword == true ? "修改登录密码" : "设置登录密码", systemImage: "lock"); Spacer(); Text(configuredPassword == true ? "已设置" : "邮箱验证").font(.footnote).foregroundStyle(theme.secondaryInk) }.frame(minHeight: 44) }.accessibilityIdentifier("account.password.setup")
            if account.hasPremiumEntitlement {
                if let entitlement = account.entitlements.first(where: { $0.product_code == "riverdiary_premium" }) {
                    LabeledContent("高级权益", value: entitlement.permanent ? "永久有效" : "有效至 \(entitlement.expires_at.map(Self.displayDate) ?? "—")")
                }
            } else {
                LabeledContent("高级权益", value: "未激活")
            }

            TextField("输入激活 / 兑换码", text: $activationCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .riverField(leadingSymbol: "key")
                .accessibilityIdentifier("account.activationCode")
                .onChange(of: activationCode) { _, _ in redeemRequestID = UUID().uuidString }

            Button {
                Task { await redeem() }
            } label: {
                if account.isBusy { ProgressView().frame(maxWidth: .infinity) }
                else { Text("兑换激活码").frame(maxWidth: .infinity) }
            }
            .riverPrimary()
            .disabled(account.isBusy || activationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("account.redeem")

            if let message { Text(message).font(.footnote).foregroundStyle(theme.accentText) }
            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(theme.danger) }

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
            .font(.subheadline).frame(minHeight: 44)

            Button("退出账号", role: .destructive) {
                Task { await account.signOut() }
            }.frame(minHeight: 44)
            }
        }
        .task {
            guard account.isSignedIn else { return }
            try? await account.refreshEntitlements()
        }
        .sheet(isPresented: $showsPasswordSetup) { RiverPasswordRecoveryView(initialEmail: account.accountEmail ?? "", isSetup: true) }
        .sheet(isPresented: $showsLogin) {
            AccountLoginView(allowsDismiss: true)
                .environmentObject(account)
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("绑定后，本机已有的日记会归当前账号", isPresented: $showsBindConfirmation, titleVisibility: .visible) {
            Button("继续绑定") { showsLogin = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这台 iPhone 已有本机日记或快记。绑定成功后，本机资料归当前账号；换另一个账号登录会被拒绝。未绑定时数据仍在本机。")
        }
        .task { if account.isSignedIn { configuredPassword = try? await account.passwordEnabled() } }
        .onChange(of: showsPasswordSetup) { _, shown in if !shown { Task { configuredPassword = try? await account.passwordEnabled() } } }

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
