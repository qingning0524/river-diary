import SwiftUI

// MARK: - Panel system
//
// One container for every surface in the app. A page is a vertical stack of
// `RiverPanel`s; a panel has an optional header, one hairline outline, and rows
// separated by inset dividers. Nothing else draws its own card.

/// How far a surface floats above the page canvas.
enum RiverPanelLevel: Hashable {
    /// Sits in a scrolling page column. Flat: outline only.
    case inline
    /// A panel on a panel, or a toolbar strip. Barely lifted.
    case raised
    /// Sheets, popovers, drawers and the lock gate. Fully lifted.
    case floating
}

/// The panel chrome: fill, outline, radius and elevation for one level.
/// 柔和景深: `.raised` and `.floating` float with a two-tier shadow — a tight
/// contact shadow plus a wide, low-opacity ambient shadow. `.inline` carries no
/// shadow at all, by design: dozens of shadowed panels in one scroll view is
/// slow to render and visually noisy; page depth comes from the canvas/panel
/// colour step instead.
struct RiverPanelSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let level: RiverPanelLevel
    let radius: CGFloat
    var tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(Color.border, lineWidth: 1))
        if level == .inline {
            base
        } else {
            base
                .shadow(color: contactShadow, radius: contactRadius, y: contactY)
                .shadow(color: ambientShadow, radius: ambientRadius, y: ambientY)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var dark: Bool { colorScheme == .dark }

    private var fill: AnyShapeStyle {
        guard let tint else {
            return AnyShapeStyle(level == .inline ? Color.surface : Color.strongSurface)
        }
        return AnyShapeStyle(LinearGradient(
            colors: [
                tint.opacity(dark ? 0.20 : 0.11),
                Color(hex: PaletteStore.colorSet(dark: dark).surface),
            ],
            startPoint: .topLeading,
            endPoint: .bottom
        ))
    }

    private var contactShadow: Color {
        if level == .floating { return .black.opacity(dark ? 0.32 : 0.07) }
        return .black.opacity(dark ? 0.24 : 0.04)
    }

    private var contactRadius: CGFloat {
        if level == .floating { return 6 }
        return 3
    }

    private var contactY: CGFloat {
        if level == .floating { return 3 }
        return 1
    }

    private var ambientShadow: Color {
        if level == .floating { return .black.opacity(dark ? 0.45 : 0.18) }
        return .black.opacity(dark ? 0.28 : 0.08)
    }

    private var ambientRadius: CGFloat {
        if level == .floating { return 38 }
        return 24
    }

    private var ambientY: CGFloat {
        if level == .floating { return 14 }
        return 9
    }
}

extension View {
    /// Applies the canonical panel chrome without any content padding.
    func riverPanelSurface(_ level: RiverPanelLevel = .inline, radius: CGFloat = AppRadius.panel, tint: Color? = nil) -> some View {
        modifier(RiverPanelSurface(level: level, radius: radius, tint: tint))
    }
}

// MARK: - Panel header

/// The standard panel header: an optional tinted icon well, a title, and quiet
/// metadata. Concrete (not generic) so `RiverPanel` can use it as a default.
struct RiverPanelTitle: View {
    @Environment(\.riverDensity) private var density
    var title: String?
    var systemImage: String?
    var detail: String?
    var accent: Color?
    var trailingText: String?

    var body: some View {
        HStack(spacing: density.spacing(10)) {
            if let systemImage {
                RiverIconWell(systemImage: systemImage, tint: accent ?? AppTheme.neutral)
            } else if let accent {
                Capsule()
                    .fill(accent)
                    .frame(width: 3, height: 13)
            }
            if let title {
                Text(title)
                    .font(AppTypography.sectionTitle())
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: density.spacing(8))
            if let detail {
                Text(detail)
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.secondaryInk)
                    .lineLimit(1)
            }
            if let trailingText {
                Text(trailingText)
                    .font(AppTypography.numeric())
                    .foregroundStyle(Color.secondaryInk)
            }
        }
        .padding(.horizontal, density.spacing(AppSpacing.panelPadding))
        .padding(.vertical, density.spacing(11))
        .frame(minHeight: 44)
    }
}

/// A tinted circle that holds one glyph. The single way the app draws an icon
/// that is meant to carry meaning.
struct RiverIconWell: View {
    let systemImage: String
    var tint: Color = AppTheme.neutral
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                tint.opacity(0.12),
                in: Circle()
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Panel

/// The canonical panel.
///
/// ```swift
/// RiverPanel(title: "时间分布", systemImage: "chart.bar", accent: AppTheme.accent) {
///     RiverPanelRow(title: "学习", detail: "3 段") { Text("2 小时") }
/// }
/// ```
struct RiverPanel<Header: View, Content: View>: View {
    @Environment(\.riverDensity) private var density
    var level: RiverPanelLevel = .inline
    /// Inner padding of the content area. `nil` uses the canonical padding.
    var padding: CGFloat?
    /// Optional accent wash in the fill — reserved for a page's anchor card.
    var tint: Color?
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header()
            // 必须把内容先收进一个自己的 VStack 再加内边距。
            // 直接写 `content().padding(...)` 时，`content` 是 ViewBuilder 产出的多元组，
            // SwiftUI 会把 padding **分给每一个子视图**，于是每行都多出上下各 18pt：
            // 行距从 47pt 变成 83pt（像素实测：面板分隔线正好相距 83pt），
            // 整个应用的面板都异常松散。收进 VStack 后 padding 只作用一次，回到设计意图。
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, density.spacing(padding ?? AppSpacing.panelPadding))
            .padding(.vertical, density.spacing(padding ?? AppSpacing.panelPadding))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .riverPanelSurface(level, tint: tint)
    }
}

extension RiverPanel where Header == RiverPanelTitle {
    /// A panel with the standard title header.
    init(
        title: String? = nil,
        systemImage: String? = nil,
        detail: String? = nil,
        accent: Color? = nil,
        trailingText: String? = nil,
        level: RiverPanelLevel = .inline,
        padding: CGFloat? = nil,
        tint: Color? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.level = level
        self.padding = padding
        self.tint = tint
        self.header = {
            RiverPanelTitle(
                title: title,
                systemImage: systemImage,
                detail: detail,
                accent: accent,
                trailingText: trailingText
            )
        }
        self.content = content
    }
}

extension RiverPanel where Header == EmptyView {
    /// A plain panel: content only, no header and no divider.
    init(
        level: RiverPanelLevel = .inline,
        padding: CGFloat? = nil,
        tint: Color? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.level = level
        self.padding = padding
        self.tint = tint
        self.header = { EmptyView() }
        self.content = content
    }
}

// MARK: - Panel header scaffold

/// Wraps a header view so that a panel header always ends with the same
/// full-bleed hairline, including custom headers.

// MARK: - Rules

/// A full-bleed hairline.
struct RiverRule: View {
    var color: Color = Color.separator

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
    }
}

/// A hairline inset so it starts where row text starts.
struct RiverRowDivider: View {
    @Environment(\.riverDensity) private var density
    var inset: CGFloat = AppSpacing.dividerInset
    var leadingExtra: CGFloat = 0

    var body: some View {
        RiverRule()
            .padding(.leading, density.spacing(inset) + leadingExtra)
    }
}

// MARK: - Rows

/// A row inside a panel: title, optional detail, and a trailing control or
/// value. Rows carry their own divider so panels never hand-draw them.
struct RiverPanelRow<Content: View>: View {
    @Environment(\.riverDensity) private var density
    var title: String
    var detail: String?
    var systemImage: String?
    var showsDivider = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: density.spacing(10)) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondaryInk)
                        .frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppTypography.rowTitle())
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: density.spacing(8))
                content()
            }
            .padding(.vertical, density.spacing(7))
            .frame(minHeight: density.spacing(AppSpacing.rowHeight))

            if showsDivider { RiverRowDivider(leadingExtra: systemImage == nil ? 0 : 26) }
        }
    }
}

extension RiverPanelRow where Content == EmptyView {
    /// A label-only row, for panels that just list facts.
    init(title: String, detail: String? = nil, systemImage: String? = nil, showsDivider: Bool = true) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.showsDivider = showsDivider
        self.content = { EmptyView() }
    }
}

/// A label / value row: the shape most evidence panels need.
struct RiverValueRow: View {
    @Environment(\.riverDensity) private var density
    var title: String
    var value: String
    var detail: String?
    var valueTint: Color = Color.ink
    var showsDivider = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: density.spacing(10)) {
                Text(title)
                    .font(AppTypography.rowTitle())
                    .foregroundStyle(Color.ink)
                    .frame(minWidth: 72, alignment: .leading)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.secondaryInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: density.spacing(8))
                Text(value)
                    .font(AppTypography.numeric())
                    .foregroundStyle(valueTint)
                    .lineLimit(1)
            }
            .padding(.vertical, density.spacing(7))
            .frame(minHeight: density.spacing(AppSpacing.rowHeight))

            if showsDivider { RiverRowDivider(leadingExtra: 0) }
        }
    }
}

// MARK: - Section headings

/// Group heading on a page: the quiet uppercase label that gets out of the way.
struct RiverGroupLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(AppTypography.kicker())
            .tracking(0.9)
            .foregroundStyle(Color.secondaryInk)
    }
}

/// Heading above a panel or a group of rows.
struct RiverSectionHeading: View {
    @Environment(\.riverDensity) private var density
    var title: String
    var detail: String?
    var kicker: String?

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(2)) {
            if let kicker, !kicker.isEmpty {
                RiverGroupLabel(text: kicker)
            }
            Text(title)
                .font(AppTypography.sectionTitle())
                .foregroundStyle(Color.ink)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Small building blocks

/// A metric inside a panel: value first, then the label that qualifies it.
struct RiverStat: View {
    @Environment(\.riverDensity) private var density
    var title: String
    var value: String
    var detail: String?
    var valueFont: Font = AppTypography.metricSmall()

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(3)) {
            Text(title)
                .font(AppTypography.metadata())
                .foregroundStyle(Color.secondaryInk)
            Text(value)
                .font(valueFont)
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.tertiaryInk)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A horizontal strip of `RiverStat`s separated by hairlines.

/// Hairline separator used between `RiverStat`s in a strip.
struct RiverStatDivider: View {
    var body: some View {
        RiverRule(color: Color.separator)
            .frame(width: 1, height: 34)
            .padding(.horizontal, AppSpacing.md)
    }
}

// MARK: - Settings scaffold

/// The scroll column used by every settings section.
struct SettingsPage<Content: View>: View {
    @Environment(\.riverDensity) private var density
    /// 版心宽度按设置窗口的内容列定：窗口 760 − 左栏 168 − 1pt 发丝线。
    var maxWidth: CGFloat = AppLayout.settingsColumnMaxWidth
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sectionGap)) {
                content()
            }
            // 与页面标题共用版心上限和左内边距（`AppSpacing.page`），并且**左对齐**：
            // 标题贴在左边缘、面板却居中缩在中间，是设置页看起来"散"的主因。
            .frame(maxWidth: maxWidth, alignment: .topLeading)
            .padding(.horizontal, density.spacing(AppSpacing.page))
            .padding(.top, density.spacing(AppSpacing.xl))
            .padding(.bottom, density.spacing(AppSpacing.xxl))
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .riverScrollIndicators()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.workspace)
    }
}

/// A titled group of settings rows.
struct SettingsGroup<Content: View>: View {
    @Environment(\.riverDensity) private var density
    var title: String
    var detail: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(10)) {
            RiverSectionHeading(title: title, detail: detail)
            content()
        }
    }
}

/// The explanatory footnote under a group. One line of copy, never a wall.
struct SettingsFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTypography.metadata())
            .foregroundStyle(Color.secondaryInk)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 一条安静的说明：图标 + 一句话 +（可选）一个动作和一次关闭。
///
/// 用在"数据少了一块、而且是可修的"这种地方：窗口标题没采到、某个来源没在跑。
/// 它不是警告条——底色是 `chip`、文字是次级墨色，只有图标带一点色；出错有
/// `StatusBadge` 和证据控制台，这里要的是被读到，不是被吓一跳。
struct RiverInlineNotice: View {
    @Environment(\.riverDensity) private var density
    let systemImage: String
    let text: String
    var tint: Color = AppTheme.neutral
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: density.spacing(AppSpacing.sm)) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(AppTypography.metadata())
                .foregroundStyle(Color.secondaryInk)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: density.spacing(AppSpacing.sm))
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .smallAction(dark: true)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .iconAction()
                .accessibilityLabel("不再提示")
                .help("不再提示")
            }
        }
        .padding(.horizontal, density.spacing(AppSpacing.sm))
        .padding(.vertical, density.spacing(6))
        .background(Color.chip, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                .strokeBorder(Color.border, lineWidth: 1)
        )
    }
}
