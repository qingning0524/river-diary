import SwiftUI

// MARK: - Page scaffold
//
// Every destination page is: one scroll column, one max reading width, panels
// stacked with the canonical gap. Pages compose this instead of hand-rolling
// ScrollView + padding + background.

/// The scrolling column shared by every page: one max reading width, the page
/// gutter, and the canonical gaps between stacked panels.
struct RiverPageBody<Content: View>: View {
    @Environment(\.riverDensity) private var density
    var maxWidth: CGFloat = AppLayout.contentMaxWidth
    var spacing: CGFloat = AppSpacing.panelGap
    var topPadding: CGFloat = 0
    var bottomPadding: CGFloat = 40
    var showsIndicators = false
    /// Use a lazy stack when the page can hold a long, unbounded row list.
    var lazy = false
    private let scrollContent: (ScrollViewProxy) -> Content

    init(
        maxWidth: CGFloat = AppLayout.contentMaxWidth,
        spacing: CGFloat = AppSpacing.panelGap,
        topPadding: CGFloat = 0,
        bottomPadding: CGFloat = 40,
        showsIndicators: Bool = false,
        lazy: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.maxWidth = maxWidth
        self.spacing = spacing
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.showsIndicators = showsIndicators
        self.lazy = lazy
        self.scrollContent = { _ in content() }
    }

    init(
        maxWidth: CGFloat = AppLayout.contentMaxWidth,
        spacing: CGFloat = AppSpacing.panelGap,
        topPadding: CGFloat = 0,
        bottomPadding: CGFloat = 40,
        showsIndicators: Bool = false,
        lazy: Bool = false,
        @ViewBuilder scrollContent: @escaping (ScrollViewProxy) -> Content
    ) {
        self.maxWidth = maxWidth
        self.spacing = spacing
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.showsIndicators = showsIndicators
        self.lazy = lazy
        self.scrollContent = scrollContent
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if lazy {
                        LazyVStack(alignment: .leading, spacing: density.spacing(spacing)) { scrollContent(proxy) }
                    } else {
                        VStack(alignment: .leading, spacing: density.spacing(spacing)) { scrollContent(proxy) }
                    }
                }
                .frame(maxWidth: maxWidth, alignment: .topLeading)
                .padding(.top, density.spacing(topPadding))
                .padding(.horizontal, density.spacing(AppSpacing.page))
                .padding(.bottom, density.spacing(bottomPadding))
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .riverScrollIndicators()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.workspace)
        }
    }
}

/// A page whose header scrolls away with the content. Most destinations use this.
struct RiverPage<Content: View>: View {
    var maxWidth: CGFloat = AppLayout.contentMaxWidth
    var spacing: CGFloat = AppSpacing.panelGap
    var topPadding: CGFloat = AppSpacing.headerTop
    var bottomPadding: CGFloat = 40
    var showsIndicators = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        RiverPageBody(
            maxWidth: maxWidth,
            spacing: spacing,
            topPadding: topPadding,
            bottomPadding: bottomPadding,
            showsIndicators: showsIndicators,
            content: content
        )
    }
}

/// A page whose header stays put while the body scrolls (记忆, 设置). Uses the
/// same gutter, max width and vertical rhythm as `RiverPage`, so a fixed header
/// and a scrolling header put their content on the same line.
struct RiverHeaderBand<Content: View>: View {
    @Environment(\.riverDensity) private var density
    var maxWidth: CGFloat = AppLayout.contentMaxWidth
    var spacing: CGFloat = AppSpacing.lg
    var showsRule = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: density.spacing(spacing)) {
                content()
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.top, density.spacing(AppSpacing.headerTop))
            .padding(.horizontal, density.spacing(AppSpacing.page))
            .padding(.bottom, density.spacing(AppSpacing.headerBottom))
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsRule { RiverRule() }
        }
        .background(Color.workspace)
    }
}

// MARK: - Page header
//
// One anatomy for every destination: title, one line of context, actions on the
// right. There is no page-level kicker — the title already says where you are.

struct PageHeader<Trailing: View>: View {
    @Environment(\.riverDensity) private var density
    let title: String
    var context: String?
    /// Optional capsule badge rendered beside the title (e.g. 今天).
    var badge: String?
    /// Larger rounded title for the app's anchor page.
    var emphasis = false
    var trailing: Trailing

    init(
        _ title: String,
        context: String? = nil,
        badge: String? = nil,
        emphasis: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.context = context
        self.badge = badge
        self.emphasis = emphasis
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: density.spacing(AppSpacing.md)) {
            VStack(alignment: .leading, spacing: density.spacing(3)) {
                HStack(alignment: .firstTextBaseline, spacing: density.spacing(AppSpacing.sm)) {
                    Text(title)
                        .font(emphasis ? AppTypography.pageTitleLarge() : AppTypography.pageTitle())
                        .foregroundStyle(Color.ink)
                    if let badge, !badge.isEmpty {
                        Text(badge)
                            .font(AppTypography.micro().weight(.semibold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, density.spacing(AppSpacing.sm))
                            .padding(.vertical, density.spacing(3))
                            .background(AppTheme.accentSoft, in: Capsule())
                    }
                }
                if let context, !context.isEmpty {
                    Text(context)
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.secondaryInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: density.spacing(AppSpacing.md))
            trailing
        }
        .accessibilityElement(children: .contain)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: String, context: String? = nil) {
        self.init(title, context: context) { EmptyView() }
    }
}

// MARK: - Sidebar
//
// The navigation rail: identity, date context, grouped destinations, and one
// honest status footer. Selection is always the same pale-blue surface with a
// leading accent rule.

struct SidebarNavRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.riverHighContrast) private var highContrast
    @Environment(\.riverDensity) private var density

    let title: String
    let symbol: String
    var shortcut: String?
    var badge: String?
    /// 数字徽标用强调色胶囊（如习惯回顾的待确认题数）；
    /// 默认文字徽标保持警示色（如"未保存"）。
    var badgeIsCount = false
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var foreground: Color {
        if isSelected || isHovered || highContrast { return Color.ink }
        return Color.secondaryInk
    }

    private var fill: Color {
        if isSelected { return AppTheme.accentSoft }
        if isHovered { return reduceTransparency ? Color.surface : Color.ink.opacity(0.05) }
        return .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: density.spacing(9)) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? AppTheme.accent : foreground)
                    .frame(width: 18)
                Text(title)
                    .font(AppTypography.rowTitle().weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                Spacer(minLength: density.spacing(AppSpacing.xs))
                if let badge {
                    if badgeIsCount {
                        Text(badge)
                            .font(AppTypography.micro().weight(.bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, density.spacing(6))
                            .padding(.vertical, density.spacing(2))
                            .background(AppTheme.accent, in: Capsule())
                            .accessibilityHidden(true)
                    } else {
                        Text(badge)
                            .font(AppTypography.micro().weight(.medium))
                            .foregroundStyle(AppTheme.warning)
                    }
                }
                if let shortcut, isSelected {
                    Text(shortcut)
                        .font(AppTypography.kicker())
                        .foregroundStyle(Color.tertiaryInk)
                }
            }
            .padding(.horizontal, density.spacing(10))
            .frame(minHeight: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(AppTheme.accent)
                        .frame(width: 2.5)
                        .padding(.vertical, density.spacing(6))
                        .padding(.leading, density.spacing(1))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, density.spacing(AppSpacing.sm))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: AppMotion.quick), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: AppMotion.standard), value: isSelected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A labelled group of sidebar destinations.
struct SidebarGroup<Content: View>: View {
    @Environment(\.riverDensity) private var density
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(1)) {
            RiverGroupLabel(text: title)
                .padding(.horizontal, density.spacing(AppSpacing.panelPadding))
                .padding(.top, density.spacing(10))
                .padding(.bottom, density.spacing(AppSpacing.xxs))
            content()
        }
    }
}

/// App identity at the top of the rail.
struct SidebarIdentity: View {
    @Environment(\.riverDensity) private var density

    var body: some View {
        HStack(spacing: density.spacing(9)) {
            BrandMark(size: 26)
            VStack(alignment: .leading, spacing: density.spacing(1)) {
                Text("河流日记")
                    .font(AppTypography.rowTitle().weight(.semibold))
                    .foregroundStyle(Color.ink)
                Text("本机证据库")
                    .font(AppTypography.micro())
                    .foregroundStyle(Color.secondaryInk)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, density.spacing(AppSpacing.panelPadding))
        .padding(.top, density.spacing(AppSpacing.md))
        .padding(.bottom, density.spacing(10))
    }
}

/// One glanceable source status line for the sidebar footer.
extension SidebarFooter {
    struct StatusLine: Hashable {
        let color: Color
        let text: String
    }
}

/// The pinned sidebar footer: glanceable source status lines, with the
/// settings shortcut on the last line.
struct SidebarFooter: View {
    @Environment(\.riverDensity) private var density
    let statusLines: [StatusLine]
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xs)) {
            ForEach(Array(statusLines.enumerated()), id: \.offset) { index, line in
                HStack(spacing: density.spacing(5)) {
                    Circle()
                        .fill(line.color)
                        .frame(width: 5, height: 5)
                    Text(line.text)
                        .font(AppTypography.micro())
                        .foregroundStyle(Color.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: density.spacing(AppSpacing.xs))
                    if index == statusLines.count - 1 {
                        Button("设置", action: onOpenSettings)
                            .buttonStyle(.plain)
                            .font(AppTypography.micro())
                            .foregroundStyle(AppTheme.accent)
                    }
                }
            }
        }
        .padding(.horizontal, density.spacing(AppSpacing.reading))
        .padding(.vertical, density.spacing(9))
        .accessibilityElement(children: .contain)
    }
}
