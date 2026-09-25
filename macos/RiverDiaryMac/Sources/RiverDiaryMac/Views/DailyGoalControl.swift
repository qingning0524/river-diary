import SwiftUI

struct DailyGoalControl: View {
    @Environment(\.riverDensity) private var density
    @ObservedObject var store: DiaryStore
    let date: Date

    @State private var isEditing = false
    @State private var draft = ""
    @State private var showRemoveConfirmation = false
    @State private var errorMessage: String?

    private var goal: DailyGoal? { store.dailyGoal(for: date) }
    private var dateKey: String { DiaryEntry.dateFormatter.string(from: date) }
    private var dateName: String {
        Calendar.current.isDateInToday(date) ? "今日" : date.formatted(.dateTime.month().day())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(7)) {
            HStack(spacing: density.spacing(7)) {
                Image(systemName: "target")
                    .foregroundStyle(AppTheme.accent)
                Text("\(dateName)目标")
                    .font(AppTypography.sectionTitle())
                    .foregroundStyle(Color.ink)
                Spacer()
                if let goal {
                    Text(goal.isCompleted ? "手动确认完成" : "进行中")
                        .font(AppTypography.metadata())
                        .foregroundStyle(goal.isCompleted ? AppTheme.ok : Color.secondaryInk)
                }
            }

            if isEditing {
                TextField("写下今天最重要的一件事", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                HStack {
                    Button("取消", action: cancelEditing)
                        .buttonStyle(.plain)
                        .smallAction()
                    Spacer()
                    Button("保存目标", action: save)
                        .primaryCTA()
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if let goal {
                Text(goal.title)
                    .font(AppTypography.secondary())
                    .foregroundStyle(Color.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: density.spacing(AppSpacing.sm)) {
                    Button(goal.isCompleted ? "恢复进行中" : "我已完成") {
                        updateCompletion(!goal.isCompleted)
                    }
                    .primaryCTA()
                    Button("修改") {
                        draft = goal.title
                        errorMessage = nil
                        isEditing = true
                    }
                    .buttonStyle(.plain)
                    .smallAction()
                    Button("移除", role: .destructive) {
                        showRemoveConfirmation = true
                    }
                    .buttonStyle(.plain)
                    .font(AppTypography.metadata())
                    Spacer()
                    Text("由你设定")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.tertiaryInk)
                }
            } else {
                HStack {
                    Text("尚未设定；完成状态由你确认，不会由 AI 推断。")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.secondaryInk)
                    Spacer(minLength: 8)
                    Button("设定目标") {
                        draft = ""
                        errorMessage = nil
                        isEditing = true
                    }
                    .buttonStyle(.plain)
                    .smallAction()
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(AppTypography.metadata())
                    .foregroundStyle(AppTheme.error)
            }
        }
        .confirmationDialog(
            "移除\(dateName)目标？",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("移除目标", role: .destructive) { removeGoal() }
            Button("取消", role: .cancel) { }
        }
        .onChange(of: dateKey) { _, _ in cancelEditing() }
    }

    private func save() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            try store.saveDailyGoal(DailyGoal(title: title, isCompleted: goal?.isCompleted ?? false), for: date)
            errorMessage = nil
            isEditing = false
        } catch {
            errorMessage = "保存失败：\(UserFacingError.message(for: error))"
        }
    }

    private func updateCompletion(_ isCompleted: Bool) {
        guard let goal else { return }
        do {
            try store.saveDailyGoal(DailyGoal(title: goal.title, isCompleted: isCompleted), for: date)
            errorMessage = nil
        } catch {
            errorMessage = "保存失败：\(UserFacingError.message(for: error))"
        }
    }

    private func removeGoal() {
        do {
            try store.saveDailyGoal(nil, for: date)
            errorMessage = nil
        } catch {
            errorMessage = "移除失败：\(UserFacingError.message(for: error))"
        }
    }

    private func cancelEditing() {
        draft = ""
        errorMessage = nil
        isEditing = false
    }
}
