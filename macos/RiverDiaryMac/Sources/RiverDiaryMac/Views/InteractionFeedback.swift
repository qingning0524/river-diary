import AppKit
import SwiftUI

enum FeedbackKind: Equatable {
    case success, info, warning, error

    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success: AppTheme.ok
        case .info: AppTheme.accent
        case .warning: AppTheme.warning
        case .error: AppTheme.error
        }
    }
}

struct FeedbackMessage: Identifiable, Equatable {
    let id = UUID()
    let kind: FeedbackKind
    let text: String
}

@MainActor
final class FeedbackCenter: ObservableObject {
    @Published private(set) var message: FeedbackMessage?
    private var dismissTask: Task<Void, Never>?

    /// 每类提示的存留时长。错误必须由用户确认关闭——保存失败这类需要
    /// 行动的信息不能 3 秒后无声消失。
    private static func lifetime(for kind: FeedbackKind) -> Task<Void, Never>? {
        switch kind {
        case .error: nil
        case .warning: Task { try? await Task.sleep(for: .seconds(8)) }
        case .success, .info: Task { try? await Task.sleep(for: .seconds(3)) }
        }
    }

    func show(_ text: String, kind: FeedbackKind = .info) {
        dismissTask?.cancel()
        message = FeedbackMessage(kind: kind, text: text)
        if let lifetime = Self.lifetime(for: kind) {
            dismissTask = Task { @MainActor in
                await lifetime.value
                guard !Task.isCancelled else { return }
                message = nil
            }
        } else {
            dismissTask = nil
        }
        announceIfNeeded(kind: kind, text: text)
    }

    func clear() { dismissTask?.cancel(); message = nil }

    /// VoiceOver：顶部 banner 是纯视觉层，旁白用户感知不到"已保存/失败"，
    /// 展示时同步发一条播报。
    private func announceIfNeeded(kind: FeedbackKind, text: String) {
        guard kind != .success else { return }
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: NSAttributedString(string: text),
                .priority: NSNumber(value: kind == .error ? 2 : 1),
            ]
        )
    }
}

/// The single transient feedback surface. Floating level so it reads as an
/// overlay above the workspace, using the same radius and border language as
/// every other panel.
struct RiverFeedbackBanner: View {
    let message: FeedbackMessage
    var onClose: () -> Void = {}

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: message.kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(message.kind.tint)
            Text(message.text)
                .font(AppTypography.rowTitle())
                .foregroundStyle(Color.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if message.kind == .error || message.kind == .warning {
                // 常驻类提示必须带出口，否则只能等下一条提示顶掉它。
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.tertiaryInk)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭提示")
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(
            Color.strongSurface,
            in: RoundedRectangle(cornerRadius: AppRadius.floating, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.floating, style: .continuous)
                .strokeBorder(message.kind.tint.opacity(0.30), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 7)
        .accessibilityElement(children: .combine)
    }
}
