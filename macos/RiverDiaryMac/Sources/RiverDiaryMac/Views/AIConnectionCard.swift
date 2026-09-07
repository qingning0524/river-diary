import SwiftUI

struct AIConnectionCard: View {
    @ObservedObject var ai: AIAssistantStore

    var body: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("连接模型 API", systemImage: "sparkles.rectangle.stack")
                        .font(.headline)
                    Spacer()
                    StatusBadge(ai.isConfigured ? "已连接" : "未连接", tone: ai.isConfigured ? .positive : .neutral)
                }

                Text("支持 OpenAI 兼容、DeepSeek、Moonshot、OpenRouter、阿里云百炼、智谱、xAI、Groq、Mistral、SiliconFlow、Ollama 和 LM Studio。可以保存多个方案，随时切换。")
                    .font(.caption)
                    .lineSpacing(6)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
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
                        .frame(width: 220)

                        Button("新增方案") { ai.addProfile() }
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

                    HStack(spacing: 10) {
                        TextField("方案名称", text: Binding(
                            get: { ai.profileName },
                            set: { ai.profileName = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                        Picker("服务商", selection: $ai.provider) {
                            ForEach(AIProvider.allCases) { provider in
                                Text(provider.label).tag(provider)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 190)

                        Toggle("发送窗口标题", isOn: $ai.includeTitles)
                            .toggleStyle(.switch)
                            .font(.caption)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("API 地址")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("https://api.example.com/v1/chat/completions", text: $ai.endpoint)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    }

                    if ai.providerRequiresAPIKey {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("API Key")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                SecureField(ai.hasAPIKey ? "已保存到钥匙串" : "粘贴 API Key", text: $ai.apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                Button("保存 Key") { ai.saveAPIKey() }
                                    .buttonStyle(.plain)
                                    .smallAction()
                                if ai.hasAPIKey {
                                    Button("移除") { ai.deleteAPIKey() }
                                        .buttonStyle(.plain)
                                        .smallAction()
                                }
                            }
                        }
                    } else {
                        Label("本地模型不需要 API Key。", systemImage: "desktopcomputer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("模型名称")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if ai.availableModels.isEmpty {
                            TextField("例如 gpt-4o-mini / deepseek-chat / qwen-plus", text: $ai.model)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                        } else {
                            Picker("可用模型", selection: Binding(
                                get: { ai.availableModels.contains(ai.model) ? ai.model : (ai.model.isEmpty ? "" : "__manual__") },
                                set: { newValue in
                                    if newValue != "__manual__" {
                                        ai.model = newValue
                                    }
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
                            .frame(maxWidth: .infinity, alignment: .leading)

                            TextField("手动输入模型名称", text: $ai.model)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                        }

                        HStack(spacing: 8) {
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

                            Spacer()

                            Text(ai.isConfigured ? "已可使用" : ai.canTestConnection ? "Key 待保存，测试时会自动保存" : ai.providerRequiresAPIKey ? "还需要 API Key、地址和模型" : "还需要地址和模型")
                                .font(.caption)
                                .foregroundStyle(ai.isConfigured ? Color(hex: "#2C8158") : .secondary)
                        }

                        if let message = ai.modelMessage {
                            Label(message, systemImage: message.contains("失败") ? "exclamationmark.triangle" : "list.bullet")
                                .font(.caption)
                                .foregroundStyle(message.contains("失败") ? .red : Color(hex: "#2C8158"))
                        }
                    }

                    HStack(spacing: 8) {
                        Button("清除回答") { ai.resetAnswer() }
                            .buttonStyle(.plain)
                            .smallAction()
                        Spacer()
                        if let summary = ai.requestSummary {
                            Text("上次请求：\(summary)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let message = ai.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .frame(maxWidth: 1280)
    }
}
