import SwiftUI
import UIKit

// MARK: - River OS identity

struct RiverBrandMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for offset in [0.0, 0.20] {
            path.move(to: CGPoint(x: rect.width * (0.63 + offset), y: rect.height * 0.08))
            path.addCurve(to: CGPoint(x: rect.width * (0.22 + offset), y: rect.height * 0.92),
                          control1: CGPoint(x: rect.width * (0.02 + offset), y: rect.height * 0.30),
                          control2: CGPoint(x: rect.width * (0.95 + offset), y: rect.height * 0.65))
        }
        return path
    }
}

struct RiverSystemSignature: View {
    @Environment(\.riverTheme) private var theme
    @Environment(\.dynamicTypeSize) private var textSize
    var detail = "PERSONAL MEMORY OS"
    var body: some View {
        HStack(spacing: 10) {
            RiverBrandMark()
                .stroke(theme.accentText, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 22, height: 26)
                .accessibilityHidden(true)
            Text("RIVER OS")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(2)
                .foregroundStyle(theme.ink)
            if !textSize.isAccessibilitySize {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("River，个人记忆系统")
    }
}

// MARK: - Motion & haptics

/// One shared spring so the whole app breathes at the same pace.
extension Animation {
    static let riverSpring = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let riverGentle = Animation.easeInOut(duration: 0.22)
}

/// Central haptic vocabulary: save → success, destructive intent → warning,
/// failure → error, picking among equal options → selection, taps → soft.
@MainActor
enum RiverHaptics {
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.9) }
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

// MARK: - Icon chip

/// The supplied pages use a small raised tray, with color on the symbol.
struct RiverIconChip: View {
    @Environment(\.riverTheme) private var theme
    let symbol: String
    var tint: Color? = nil
    var size: CGFloat = 36

    private var effectiveTint: Color { tint ?? theme.accent }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(effectiveTint)
            .frame(width: size, height: size)
            .riverNeumorphic(radius: theme.chipRadius)
            .accessibilityHidden(true)
    }
}

// MARK: - Status language

enum RiverStatusTone {
    case positive, caution, critical, neutral

    var symbol: String {
        switch self {
        case .positive: "checkmark.circle.fill"
        case .caution: "exclamationmark.circle.fill"
        case .critical: "xmark.circle.fill"
        case .neutral: "info.circle.fill"
        }
    }

    func color(_ theme: RiverThemeContext) -> Color {
        switch self {
        case .positive: theme.success
        case .caution: theme.warning
        case .critical: theme.danger
        case .neutral: theme.secondaryInk
        }
    }

    func softColor(_ theme: RiverThemeContext) -> Color {
        switch self {
        case .positive: theme.successSoft
        case .caution: theme.warningSoft
        case .critical: theme.dangerSoft
        case .neutral: theme.raisedSurface
        }
    }
}

/// Status is always word + tint; the tint is never the only channel.
struct RiverStatusPill: View {
    @Environment(\.riverTheme) private var theme
    let text: String
    let tone: RiverStatusTone
    var showsIcon = true

    var body: some View {
        HStack(spacing: 4) {
            if showsIcon {
                Image(systemName: tone.symbol)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(tone.color(theme))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tone.softColor(theme), in: Capsule())
        .lineLimit(1)
    }
}

// MARK: - Feedback banner

struct RiverFeedback: Equatable, Identifiable {
    enum Tone { case success, caution, critical, info }
    let id = UUID()
    let tone: Tone
    let message: String

    var statusTone: RiverStatusTone {
        switch tone {
        case .success: .positive
        case .caution: .caution
        case .critical: .critical
        case .info: .neutral
        }
    }

    static func success(_ message: String) -> RiverFeedback { .init(tone: .success, message: message) }
    static func failure(_ message: String) -> RiverFeedback { .init(tone: .critical, message: message) }
    static func notice(_ message: String) -> RiverFeedback { .init(tone: .caution, message: message) }
    static func info(_ message: String) -> RiverFeedback { .init(tone: .info, message: message) }
}

/// Floating confirmation that survives the sheet that produced it: a save that
/// closes its editor must still be seen on the page underneath.
struct RiverFeedbackBanner: View {
    @Environment(\.riverTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let feedback: RiverFeedback

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: feedback.statusTone.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(feedback.statusTone.color(theme))
            Text(feedback.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(feedback.statusTone.softColor(theme).opacity(theme.colorScheme == .dark ? 1 : 0.94), in: RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous)
                .strokeBorder(feedback.statusTone.color(theme).opacity(0.28), lineWidth: 0.8)
        }
        .shadow(color: theme.floatingShadow.color, radius: theme.floatingShadow.radius, x: theme.floatingShadow.x, y: theme.floatingShadow.y)
        .padding(.horizontal, theme.pageGutter)
    }
}

struct RiverFeedbackBannerModifier: ViewModifier {
    @Binding var feedback: RiverFeedback?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let dismissAfter: TimeInterval = 3.2

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let feedback {
                RiverFeedbackBanner(feedback: feedback)
                    .allowsHitTesting(false)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .task(id: feedback.id) {
                        try? await Task.sleep(for: .seconds(dismissAfter))
                        withAnimation(.riverGentle) { if self.feedback?.id == feedback.id { self.feedback = nil } }
                    }
            }
        }
        .animation(reduceMotion ? .none : .riverSpring, value: feedback)
    }
}

extension View {
    /// `.riverFeedback($state)` — bind an optional `RiverFeedback` published by
    /// this screen; the banner floats at the top and dismisses itself.
    func riverFeedback(_ feedback: Binding<RiverFeedback?>) -> some View {
        modifier(RiverFeedbackBannerModifier(feedback: feedback))
    }
}

// MARK: - Empty state

/// One empty state for the whole app: quiet well, one title, one explanation,
/// one optional action. `showsChrome: false` for use inside a panel.
struct RiverEmptyState: View {
    @Environment(\.riverTheme) private var theme
    let title: String
    var detail: String? = nil
    var systemImage: String = "tray"
    var showsChrome = true
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.secondaryInk.opacity(0.75))
                .padding(.bottom, 2)
            Text(title)
                .font(theme.textFont(15, weight: .semibold))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 18)
        .modifier(RiverEmptyChrome(showsChrome: showsChrome))
        .accessibilityElement(children: .contain)
    }
}

private struct RiverEmptyChrome: ViewModifier {
    @Environment(\.riverTheme) private var theme
    let showsChrome: Bool
    func body(content: Content) -> some View {
        if showsChrome {
            content
                .background(theme.raisedSurface.opacity(0.55), in: RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous))
        } else {
            content
        }
    }
}

// MARK: - Buttons

/// The page's one primary action: filled accent, 44pt target.
struct RiverPrimaryButtonStyle: ButtonStyle {
    @Environment(\.riverTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var role: ButtonRole? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.palette.onAccent)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(fill, in: RoundedRectangle(cornerRadius: theme.chipRadius + 2, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.975 : 1)
            .animation(reduceMotion ? .easeOut(duration: 0.08) : .riverTouch, value: configuration.isPressed)
    }

    private var fill: Color {
        if role == .destructive { return theme.danger }
        return isEnabled ? theme.accent : theme.secondaryInk.opacity(0.35)
    }
}

/// Secondary action: soft raised fill, ink text.
struct RiverQuietButtonStyle: ButtonStyle {
    @Environment(\.riverTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint ?? theme.ink)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(theme.raisedSurface.opacity(0.8), in: RoundedRectangle(cornerRadius: theme.chipRadius + 2, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.98 : 1)
            .animation(reduceMotion ? .easeOut(duration: 0.08) : .riverTouch, value: configuration.isPressed)
    }
}

extension View {
    func riverPrimary(role: ButtonRole? = nil) -> some View { buttonStyle(RiverPrimaryButtonStyle(role: role)) }
    func riverQuiet(tint: Color? = nil) -> some View { buttonStyle(RiverQuietButtonStyle(tint: tint)) }
}

/// Suggestion / filter chip used by River intro and footprint filters.
struct RiverSuggestionChip: View {
    @Environment(\.riverTheme) private var theme
    let title: String
    var symbol: String? = nil
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(minHeight: 44)
            .background(isSelected ? theme.accentSoft : theme.surface, in: Capsule())
            .overlay {
                Capsule().strokeBorder(isSelected ? theme.accent.opacity(0.35) : theme.separator, lineWidth: 0.6)
            }
            .foregroundStyle(isSelected ? theme.accentText : theme.secondaryInk)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Signature ornaments

/// The soft radial orb from the approved reference: a breath of accent light,
/// used behind hero headings. Always decorative, never content-bearing.
struct RiverOrb: View {
    @Environment(\.riverTheme) private var theme
    var size: CGFloat = 84
    var tint: Color? = nil

    var body: some View {
        Circle()
            .fill(RadialGradient(
                colors: [(tint ?? theme.accent).opacity(0.34), (tint ?? theme.accent).opacity(0.12), .clear],
                center: .center, startRadius: size * 0.05, endRadius: size * 0.55
            ))
            .overlay {
                Circle()
                    .fill(RadialGradient(
                        colors: [(tint ?? theme.accent).opacity(0.5), (tint ?? theme.accent).opacity(0.08)],
                        center: .init(x: 0.38, y: 0.34), startRadius: 1, endRadius: size * 0.3
                    ))
                    .blur(radius: size * 0.08)
                    .padding(size * 0.3)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The river under a day: one honest bar of what has already been recorded.
/// It only renders when something was recorded — an unknown day shows nothing,
/// never a confident zero.
struct RiverDayFlowBar: View {
    @Environment(\.riverTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let recordedSeconds: TimeInterval
    let windowSeconds: TimeInterval
    var caption: String? = nil

    private var fraction: Double {
        guard windowSeconds > 0 else { return 0 }
        return min(1, max(0.03, recordedSeconds / windowSeconds))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.raisedSurface)
                    Capsule()
                        .fill(LinearGradient(colors: [theme.accent, theme.accent.opacity(0.72)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * fraction)
                        .animation(reduceMotion ? nil : .riverSpring, value: fraction)
                }
            }
            .frame(height: 5)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryInk)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Metric tile for the Today page: icon chip, title, observed value, source.
/// Unknown metrics are filtered out by the caller — a tile never says zero.
struct RiverMetricTile: View {
    @Environment(\.riverTheme) private var theme
    let title: String
    let value: String
    var detail: String? = nil
    let symbol: String
    var tint: Color? = nil
    var showsChevron = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                RiverIconChip(symbol: symbol, tint: tint, size: 24)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.secondaryInk)
            }
            Text(value)
                .font(theme.textFont(18, relativeTo: .title3, weight: .semibold))
                .foregroundStyle(theme.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(theme.raisedSurface.opacity(0.42), in: RoundedRectangle(cornerRadius: theme.panelRadius - 3, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.secondaryInk.opacity(0.6))
                    .padding(10)
            }
        }
    }
}

// MARK: - Surfaces

extension View {
    /// Card surface for content that is not a titled `RiverIOSPanel` but must
    /// still obey the surface system (rows in sheets, hero cards, previews).
    func riverCard(radius: CGFloat? = nil, fill: Color? = nil, padding: CGFloat = 14) -> some View {
        modifier(RiverCardModifier(radius: radius, fill: fill, padding: padding))
    }
}

private struct RiverCardModifier: ViewModifier {
    @Environment(\.riverTheme) private var theme
    var radius: CGFloat?
    var fill: Color?
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill ?? theme.surface, in: RoundedRectangle(cornerRadius: radius ?? theme.panelRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius ?? theme.panelRadius, style: .continuous)
                    .strokeBorder(theme.separator.opacity(0.75), lineWidth: theme.borderWidth)
            }
    }
}

/// Soft wash that breathes behind a page hero and fades into the canvas.
struct RiverWashHeader<Content: View>: View {
    @Environment(\.riverTheme) private var theme
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .top) {
                theme.heroWash
                    .overlay(alignment: .topTrailing) {
                        RiverOrb(size: 120).offset(x: 34, y: -26).opacity(0.55)
                    }
                    .ignoresSafeArea(edges: .top)
            }
    }
}

// MARK: - Text fields

/// Shared field look for login, search and forms.
struct RiverFieldStyle: ViewModifier {
    @Environment(\.riverTheme) private var theme
    var leadingSymbol: String? = nil

    func body(content: Content) -> some View {
        HStack(spacing: 9) {
            if let leadingSymbol {
                Image(systemName: leadingSymbol)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryInk)
            }
            content
                .font(.body)
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 46)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.chipRadius + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.chipRadius + 2, style: .continuous)
                .strokeBorder(theme.separator, lineWidth: 0.6)
        }
    }
}

extension View {
    func riverField(leadingSymbol: String? = nil) -> some View {
        modifier(RiverFieldStyle(leadingSymbol: leadingSymbol))
    }
}
