import AppKit
import SwiftUI

@MainActor
final class RestoreRecoveryBootstrap: ObservableObject {
    @Published private(set) var error: String?

    private let supportDirectory: URL?
    private let legacyDatabaseURL: URL?
    private let v2DatabaseURL: URL?
    private let activityDirectory: URL?
    private let userDefaults: UserDefaults

    init(
        supportDirectory: URL? = nil,
        legacyDatabaseURL: URL? = nil,
        v2DatabaseURL: URL? = nil,
        activityDirectory: URL? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.supportDirectory = supportDirectory
        self.legacyDatabaseURL = legacyDatabaseURL
        self.v2DatabaseURL = v2DatabaseURL
        self.activityDirectory = activityDirectory
        self.userDefaults = userDefaults
        retry()
    }

    func retry() {
        do {
            _ = try RestoreRecoveryJournal.recoverIfNeeded(
                supportDirectory: supportDirectory,
                legacyDatabaseURL: legacyDatabaseURL,
                v2DatabaseURL: v2DatabaseURL,
                activityDirectory: activityDirectory,
                userDefaults: userDefaults
            )
            error = nil
        } catch let failure {
            error = UserFacingError.message(for: failure)
        }
    }
}

struct RestoreRecoveryGateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        RiverPanel(level: .floating, padding: AppSpacing.xl) {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                HStack(spacing: AppSpacing.md) {
                    RiverIconWell(systemImage: "lock.shield", tint: AppTheme.warning, size: 36)
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text("正在保护本地数据")
                            .font(AppTypography.sheetTitle())
                            .foregroundStyle(Color.ink)
                        Text("恢复未完成，数据页面保持关闭")
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.secondaryInk)
                    }
                    Spacer(minLength: 0)
                }

                Text("上次备份恢复没有完整结束。河流日记暂时不会打开数据页面，正在尝试把各项数据恢复到开始前的状态。")
                    .font(AppTypography.secondary())
                    .foregroundStyle(Color.secondaryInk)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(AppTypography.mono())
                    .foregroundStyle(Color.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(AppSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.editor, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                            .strokeBorder(Color.border, lineWidth: 1)
                    )

                HStack(spacing: AppSpacing.sm) {
                    Button("重新尝试恢复", action: retry)
                        .primaryCTA()
                    Button("退出应用") { NSApp.terminate(nil) }
                        .buttonStyle(.plain)
                        .smallAction()
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.surface(.page))
    }
}
