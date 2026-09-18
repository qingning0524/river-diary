import SwiftUI

struct AITaskCard<Trailing: View>: View {
    @ObservedObject var ai: AIAssistantStore
    let task: AITask
    let buttonTitle: String
    let emptyMessage: String
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    private var state: AITaskState? { ai.state(for: task) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Label(task.title, systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                StatusBadge(
                    state?.isLoading == true ? "生成中" : state?.answer != nil ? "已生成" : "未生成",
                    tone: state?.isLoading == true ? .attention : state?.answer != nil ? .positive : .neutral
                )
            }

            Text(emptyMessage)
                .font(.caption)
                .lineSpacing(5)
                .foregroundStyle(.secondary)

            if let answer = state?.answer {
                Text(answer)
                    .font(.system(size: 14, weight: .medium))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.border, lineWidth: 1))
            }

            if let error = state?.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Button {
                    action()
                } label: {
                    if state?.isLoading == true {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("生成中…")
                        }
                    } else {
                        Text(buttonTitle)
                    }
                }
                .buttonStyle(.plain)
                .smallAction(dark: ai.analysisReady)
                .disabled(!ai.analysisReady || state?.isLoading == true)

                if state?.answer != nil {
                    Button("清除") { ai.clearTask(task) }
                        .buttonStyle(.plain)
                        .smallAction()
                }

                Spacer()
                trailing()
            }

            if !ai.analysisReady {
                Label("AI 模型还没连接成功，可在「设置」页处理。", systemImage: "sparkles.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension AITaskCard where Trailing == EmptyView {
    init(
        ai: AIAssistantStore,
        task: AITask,
        buttonTitle: String,
        emptyMessage: String,
        action: @escaping () -> Void
    ) {
        self.init(ai: ai, task: task, buttonTitle: buttonTitle, emptyMessage: emptyMessage, action: action, trailing: { EmptyView() })
    }
}
