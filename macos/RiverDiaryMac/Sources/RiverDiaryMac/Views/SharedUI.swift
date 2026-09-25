import SwiftUI

// MARK: - Empty state
// Explains what is missing and offers the real next action. Chrome-less by
// default so it can live inside a panel without drawing a box in a box.

struct EmptyStateView: View {
    @Environment(\.riverDensity) private var density

    let title: String
    let message: String
    var symbol: String = "sparkles"
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?
    /// Draw panel chrome for call sites that are not already inside a panel.
    var showsChrome = false

    var body: some View {
        content
            .padding(showsChrome ? density.spacing(AppSpacing.panelPadding) : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(OptionalPanelChrome(enabled: showsChrome))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: density.spacing(10)) {
            RiverIconWell(systemImage: symbol, tint: AppTheme.accent, size: 28)
            VStack(alignment: .leading, spacing: density.spacing(3)) {
                Text(title)
                    .font(AppTypography.sectionTitle())
                    .foregroundStyle(Color.ink)
                Text(message)
                    .font(AppTypography.secondary())
                    .foregroundStyle(Color.secondaryInk)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if actionTitle != nil || secondaryTitle != nil {
                HStack(spacing: density.spacing(AppSpacing.sm)) {
                    if let actionTitle, let action {
                        Button(actionTitle, action: action)
                            .primaryCTA()
                            .controlSize(.small)
                    }
                    if let secondaryTitle, let secondaryAction {
                        Button(secondaryTitle, action: secondaryAction)
                            .secondaryCTA()
                            .controlSize(.small)
                    }
                }
                .padding(.top, density.spacing(AppSpacing.xxs))
            }
        }
    }
}

private struct OptionalPanelChrome: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.riverPanelSurface(.inline)
        } else {
            content
        }
    }
}

// MARK: - Informational note block
// A quiet inline explanation: icon, title, one sentence. Used when a surface
// cannot show real data yet and needs to say why.

struct RiverInsetPanel: View {
    @Environment(\.riverDensity) private var density
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: density.spacing(10)) {
            RiverIconWell(systemImage: symbol, tint: AppTheme.accent, size: 26)
            VStack(alignment: .leading, spacing: density.spacing(3)) {
                Text(title)
                    .font(AppTypography.rowTitle())
                    .foregroundStyle(Color.ink)
                Text(message)
                    .font(AppTypography.secondary())
                    .foregroundStyle(Color.secondaryInk)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(density.spacing(AppSpacing.reading))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppTheme.accent.opacity(0.05),
            in: RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                .strokeBorder(AppTheme.accent.opacity(0.14), lineWidth: 1)
        )
    }
}

// MARK: - Segmented picker
// 应用自己的分段选择器。原生 .segmented 的蓝色选中块与系统边框
// 和整套克制的设计语言不搭：这里是 chip 底、surface 浮起段、1px 描边。

struct RiverSegmentedPicker<Option: Hashable>: View {
    @Environment(\.riverDensity) private var density
    /// VoiceOver 总标签（如"复盘范围"）。
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: density.spacing(AppSpacing.xxs)) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(AppTypography.label().weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.ink : Color.secondaryInk)
                        .padding(.horizontal, density.spacing(AppSpacing.md))
                        .frame(minHeight: density.spacing(AppSpacing.controlHeight))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    isSelected ? Color.surface : Color.clear,
                    in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .strokeBorder(isSelected ? Color.border : Color.clear, lineWidth: 1)
                )
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(density.spacing(AppSpacing.xxs))
        .background(Color.chip, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

// MARK: - Filter chip
// The one selection control for scopes, categories and filters.

struct FilterChip: View {
    @Environment(\.riverDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.label().weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.ink : Color.secondaryInk)
                .padding(.horizontal, density.spacing(10))
                .padding(.vertical, density.spacing(5))
                .background(
                    isSelected ? AppTheme.accentSoft : Color.chip,
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? AppTheme.accent.opacity(0.32) : Color.border,
                        lineWidth: 1
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: AppMotion.quick), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Search field
// One search control: memory, ask, and the command palette all use it.

struct RiverSearchField: View {
    @Environment(\.riverDensity) private var density

    var placeholder: String
    @Binding var text: String
    var symbol = "magnifyingglass"
    var onSubmit: (() -> Void)?
    var showsClearButton = true
    var focus: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: density.spacing(AppSpacing.sm)) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.tertiaryInk)
            field
            if showsClearButton, !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.tertiaryInk)
                }
                .buttonStyle(.plain)
                .help("清除")
                .accessibilityLabel("清除搜索词")
            }
        }
        .padding(.horizontal, density.spacing(11))
        .padding(.vertical, density.spacing(7))
        .background(Color.editor, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                .strokeBorder(Color.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var field: some View {
        let base = TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(AppTypography.secondary())

        if let onSubmit {
            if let focus {
                base.focused(focus).onSubmit(onSubmit)
            } else {
                base.onSubmit(onSubmit)
            }
        } else if let focus {
            base.focused(focus)
        } else {
            base
        }
    }
}
