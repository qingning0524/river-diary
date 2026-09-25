import LocalAuthentication
import SwiftUI

struct AppLockGate: View {
    let isLocked: Bool
    let message: String
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: AppSpacing.lg) {
                ZStack {
                    Circle()
                        .fill(AppTheme.accent)
                        .frame(width: 76, height: 76)
                    Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.ctaText)
                }

                VStack(spacing: AppSpacing.xs) {
                    Text("河流日记已上锁")
                        .font(AppTypography.sheetTitle())
                        .foregroundStyle(Color.ink)

                    Text("你的记录一直留在这里。想继续看的时候，解锁就好。")
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.secondaryInk)
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    onUnlock()
                } label: {
                    Label("解锁日记", systemImage: "faceid")
                }
                .primaryCTA()
                .controlSize(.large)
                .padding(.top, AppSpacing.xs)

                if !message.isEmpty {
                    Text(message)
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.secondaryInk)
                        .frame(maxWidth: 320)
                }
            }
            .padding(AppSpacing.xl)
            .frame(width: 380)
            .background(
                Color.strongSurface,
                in: RoundedRectangle(cornerRadius: AppRadius.floating, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.floating, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 26, y: 12)
        }
    }
}

@MainActor
enum AppLock {
    static func unlock(completion: @escaping (Bool, String) -> Void) {
        let context = LAContext()
        context.localizedFallbackTitle = "使用密码"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(false, "本机还没有设置密码或生物识别，暂时无法开启应用锁。")
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "解锁河流日记"
        ) { success, evaluateError in
            let text = success ? "" : (evaluateError?.localizedDescription ?? "解锁未完成。")
            Task { @MainActor in completion(success, text) }
        }
    }
}
