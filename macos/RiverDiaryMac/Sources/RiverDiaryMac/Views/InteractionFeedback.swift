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

    func show(_ text: String, kind: FeedbackKind = .info) {
        dismissTask?.cancel()
        message = FeedbackMessage(kind: kind, text: text)
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            message = nil
        }
    }

    func clear() { dismissTask?.cancel(); message = nil }
}

/// The single transient feedback surface. Floating level so it reads as an
/// overlay above the workspace, using the same radius and border language as
/// every other panel.
struct RiverFeedbackBanner: View {
    let message: FeedbackMessage

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
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
