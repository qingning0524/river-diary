import SwiftUI

struct AIRequiredSetupView: View {
    @ObservedObject var ai: AIAssistantStore
    var onComplete: () -> Void

    @State private var isVerifying = false

    private var apiProviders: [AIProvider] {
        AIProvider.allCases.filter(\.requiresAPIKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Label("连接 AI 分析", systemImage: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                Text("首次使用需要先添加一个可用的 API Key。系统会保存密钥并发起一次真实连接测试，测试通过后才会进入日记。")
                    .font(.caption)
                    .lineSpacing(5)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("服务商")
                        .setupLabel()
                    Picker("服务商", selection: $ai.provider) {
                        ForEach(apiProviders) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    .labelsHidden()
                }

                GridRow {
                    Text("API 地址")
                        .setupLabel()
                    TextField("https://api.example.com/v1/chat/completions", text: $ai.endpoint)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("API Key")
                        .setupLabel()
                    SecureField("粘贴 API Key", text: $ai.apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("模型")
                        .setupLabel()
                    TextField("例如 gpt-4o-mini / deepseek-chat", text: $ai.model)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task {
                        isVerifying = true
                        defer { isVerifying = false }
                        await ai.testConnection()
                        if ai.hasVerifiedConnection {
                            onComplete()
                        }
                    }
                } label: {
                    if isVerifying {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在验证…")
                        }
                    } else {
                        Label("验证并进入日记", systemImage: "key.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ai.canTestConnection || isVerifying)

                if ai.hasAPIKey {
                    Label("已保存", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if let message = ai.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let message = ai.modelMessage {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("API Key 会加密保存在本机，只用于连接你选择的模型服务。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(26)
        .frame(width: 560)
        .background(Color.workspace)
    }
}

private extension Text {
    func setupLabel() -> some View {
        font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 68, alignment: .leading)
    }
}
