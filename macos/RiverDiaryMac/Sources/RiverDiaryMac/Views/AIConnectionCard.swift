import SwiftUI

enum AIConnectionCopy {
    static let setupGuidance = "支持 OpenAI 兼容、DeepSeek、Moonshot、OpenRouter、阿里云百炼、智谱、xAI、Groq、Mistral、SiliconFlow、Ollama 和 LM Studio。模型连接为可选；未连接时仍可使用本机记录、时间线和数据库。只有主动测试连接或请求 AI 分析、查询时才会调用模型。"
}

struct AIConnectionCard: View {
    @ObservedObject var ai: AIAssistantStore

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "模型连接", detail: AIConnectionCopy.setupGuidance) {
                RiverPanel {
                    profileRow
                    nameRow
                    endpointRow
                    if ai.providerRequiresAPIKey { apiKeyRow }
                    modelRow
                    actionRow
                }
            }
        }
    }

    // MARK: Rows

    private var profileRow: some View {
        RiverPanelRow(title: "模型方案", detail: "可以保存多套连接并在它们之间切换") {
            HStack(spacing: AppSpacing.sm) {
                Picker("模型方案", selection: Binding(
                    get: { ai.activeProfile?.id ?? "" },
                    set: { newValue in
                        if ai.profiles.contains(where: { $0.id == newValue }) {
                            ai.selectedProfileID = newValue
                        }
                    }
                )) {
                    ForEach(ai.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 180)

                Button("新增") { ai.addProfile() }
                    .buttonStyle(.plain)
                    .smallAction()
                Button("复制") { ai.duplicateProfile() }
                    .buttonStyle(.plain)
                    .smallAction()
                Button("删除") { ai.removeProfile() }
                    .buttonStyle(.plain)
                    .smallAction()
                    .disabled(ai.profiles.count <= 1)
            }
        }
    }

    private var nameRow: some View {
        RiverPanelRow(title: "方案名称") {
            HStack(spacing: AppSpacing.sm) {
                TextField("方案名称", text: Binding(
                    get: { ai.profileName },
                    set: { ai.profileName = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(AppTypography.label())
                .frame(width: 160)

                Picker("服务商", selection: $ai.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 150)

                Toggle("发送窗口标题", isOn: $ai.includeTitles)
                    .toggleStyle(.switch)
                    .font(AppTypography.label())
            }
        }
    }

    private var endpointRow: some View {
        RiverPanelRow(title: "API 地址") {
            TextField("https://api.example.com/v1/chat/completions", text: $ai.endpoint)
                .textFieldStyle(.roundedBorder)
                .font(AppTypography.label())
                .frame(maxWidth: 320)
        }
    }

    private var apiKeyRow: some View {
        RiverPanelRow(title: "API Key", detail: ai.hasAPIKey ? "已保存在本机加密文件" : "尚未保存") {
            HStack(spacing: AppSpacing.sm) {
                SecureField(ai.hasAPIKey ? "已保存" : "粘贴 API Key", text: $ai.apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Button("保存") { ai.saveAPIKey() }
                    .buttonStyle(.plain)
                    .smallAction(dark: true)
                if ai.hasAPIKey {
                    Button("移除") { ai.deleteAPIKey() }
                        .buttonStyle(.plain)
                        .smallAction()
                }
            }
        }
    }

    private var modelRow: some View {
        RiverPanelRow(title: "模型", detail: modelStatus) {
            HStack(spacing: AppSpacing.sm) {
                if ai.availableModels.isEmpty {
                    TextField("例如 gpt-4o-mini / deepseek-chat", text: $ai.model)
                        .textFieldStyle(.roundedBorder)
                        .font(AppTypography.label())
                        .frame(maxWidth: 240)
                } else {
                    Picker("可用模型", selection: Binding(
                        get: { ai.availableModels.contains(ai.model) ? ai.model : (ai.model.isEmpty ? "" : "__manual__") },
                        set: { newValue in
                            if newValue != "__manual__" { ai.model = newValue }
                        }
                    )) {
                        if ai.availableModels.contains(ai.model) {
                            Text(ai.model).tag(ai.model)
                        } else {
                            Text(ai.model.isEmpty ? "选择可用模型" : "手动输入：\(ai.model)").tag("__manual__")
                        }
                        ForEach(ai.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 220)

                    TextField("手动输入", text: $ai.model)
                        .textFieldStyle(.roundedBorder)
                        .font(AppTypography.label())
                        .frame(width: 160)
                }
            }
        }
    }

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                Button {
                    Task { await ai.fetchAvailableModels() }
                } label: {
                    if ai.isLoadingModels {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("获取中…")
                        }
                    } else {
                        Text("获取可用模型")
                    }
                }
                .buttonStyle(.plain)
                .smallAction(dark: true)
                .disabled(ai.isLoadingModels)

                Button {
                    Task { await ai.testConnection() }
                } label: {
                    if ai.isLoading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("测试中…")
                        }
                    } else {
                        Text("测试连接")
                    }
                }
                .buttonStyle(.plain)
                .smallAction(dark: ai.canTestConnection)
                .disabled(!ai.canTestConnection || ai.isLoading)

                Spacer(minLength: AppSpacing.sm)

                StatusBadge(
                    connectionLabel,
                    tone: ai.hasVerifiedConnection ? .positive : (ai.canTestConnection ? .attention : .neutral)
                )
            }

            if let message = ai.modelMessage {
                Text(message)
                    .font(AppTypography.metadata())
                    .foregroundStyle(message.contains("失败") ? AppTheme.error : AppTheme.ok)
            }
            if let message = ai.errorMessage {
                Text(message)
                    .font(AppTypography.metadata())
                    .foregroundStyle(AppTheme.error)
            }
            if let summary = ai.requestSummary {
                Text("上次请求：\(summary)")
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.tertiaryInk)
            }

            HStack {
                Button("清除回答") { ai.resetAnswer() }
                    .buttonStyle(.plain)
                    .smallAction()
                Spacer()
            }
        }
        .padding(.top, AppSpacing.md)
    }

    private var connectionLabel: String {
        if ai.hasVerifiedConnection { return "已验证可用" }
        if ai.canTestConnection { return "待验证" }
        return "还需要 Key、地址和模型"
    }

    private var modelStatus: String {
        ai.availableModels.isEmpty ? "可以手动填写模型名称" : "已获取 \(ai.availableModels.count) 个可用模型"
    }
}
