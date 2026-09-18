import SwiftUI

// MARK: - Quiet empty state
// 用于有真实下一步的空态：解释现状 + 提供可执行动作。

struct EmptyStateView: View {
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.ui(14, weight: .semibold))
                .foregroundStyle(Color.ink)
            Text(message)
                .font(.ui(12))
                .foregroundStyle(Color.secondaryInk)
                .lineSpacing(4)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Filter chip

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.ink : Color.secondaryInk)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(isSelected ? Color.riverAmethyst.opacity(0.14) : Color.clear, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.riverAmethyst.opacity(0.35) : Color.separator.opacity(0.0),
                        lineWidth: 1
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

// MARK: - Overview statistic

struct OverviewStat: View {
    let icon: String
    let value: String
    let label: String
    var accent = false
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent ? Color.riverAmethyst : Color.secondaryInk)
                    Text(value)
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.ink)
                }
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondaryInk)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status pill / dot

struct StatusDot: View {
    enum Level {
        case idle, running, ok, warning, error
        var color: Color {
            switch self {
            case .idle: Color.secondaryInk.opacity(0.45)
            case .running: Color.riverAmethyst
            case .ok: Color(hex: "#2C8158")
            case .warning: Color.orange
            case .error: Color.red
            }
        }
    }
    let level: Level
    let label: String
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(level.color)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryInk)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

// MARK: - Section header

struct QuietSectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.secondaryInk.opacity(0.9))
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondaryInk.opacity(0.6))
            }
            Spacer()
        }
    }
}
