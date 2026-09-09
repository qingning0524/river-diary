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

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(LinearGradient.river(startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 76, height: 76)
                        .shadow(color: Color.riverAmethyst.opacity(0.35), radius: 14, y: 6)
                    Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text("河流日记已上锁")
                    .font(.ui(22, weight: .semibold))
                    .foregroundStyle(Color.ink)

                Text("你的记录一直留在这里。想继续看的时候，解锁就好。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                Button {
                    onUnlock()
                } label: {
                    Label("解锁日记", systemImage: "faceid")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.ctaBackground, in: Capsule())
                        .foregroundStyle(Color.ctaText)
                        .shadow(color: .black.opacity(0.18), radius: 12, y: 7)
                }
                .buttonStyle(.softPress)
                .padding(.top, 3)

                if !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 320)
                }
            }
            .padding(30)
            .background(Color.strongSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.border, lineWidth: 1)
            )
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
