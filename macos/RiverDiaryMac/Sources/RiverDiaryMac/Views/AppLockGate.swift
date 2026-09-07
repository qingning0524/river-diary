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
                Image(systemName: isLocked ? "lock.circle" : "lock.open.circle")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Color.secondaryInk)

                Text("河流日记已上锁")
                    .font(.system(size: 22, weight: .semibold))
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
                }
                .buttonStyle(.plain)
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
