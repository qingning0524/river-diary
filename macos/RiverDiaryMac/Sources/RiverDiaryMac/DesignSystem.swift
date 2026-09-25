import AppKit
import SwiftUI

enum RiverDensity: String, CaseIterable, Identifiable {
    case standard
    case compact

    var id: String { rawValue }
    var title: String { self == .standard ? "标准" : "紧凑" }
    var scale: CGFloat { self == .compact ? 0.84 : 1 }
    func spacing(_ value: CGFloat) -> CGFloat { value * scale }
}

private struct RiverDensityKey: EnvironmentKey {
    static let defaultValue = RiverDensity.standard
}

private struct RiverHighContrastKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var riverDensity: RiverDensity {
        get { self[RiverDensityKey.self] }
        set { self[RiverDensityKey.self] = newValue }
    }

    var riverHighContrast: Bool {
        get { self[RiverHighContrastKey.self] }
        set { self[RiverHighContrastKey.self] = newValue }
    }
}

enum RiverAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

// MARK: - Layout
//
// One measure per decision. Views compose these numbers instead of inventing
// their own widths, paddings and gaps.

enum AppLayout {
    static let sidebarWidth: CGFloat = 236
    static let sidebarMinWidth: CGFloat = 216
    static let sidebarMaxWidth: CGFloat = 288
    /// 所有页面共用同一条内容列宽：切页时版心不跳。特别宽的仪表不再破例。
    static let contentMaxWidth: CGFloat = 920
    /// Fixed width of the Today page's right-hand column (goal + facts).
    static let todayAsideWidth: CGFloat = 320
    /// 常驻证据控制台（右栏静息态）的列宽；与侧栏 Inspector 详情共用右列位置。
    static let consoleWidth: CGFloat = 300
    static let outerPadding: CGFloat = 24
    static let inspectorWidth: CGFloat = 348
    static let settingsRailWidth: CGFloat = 186
}

// MARK: - Radius
//
// A single four-step radius scale. Every rounded surface in the app uses one of
// these; raw `cornerRadius:` numbers are not allowed in views.

enum AppRadius {
    /// Marks smaller than a control: day-ribbon segments and timeline markers.
    /// Deliberately below `control`, which would round a 1.5pt-wide bar into a pill.
    static let marker: CGFloat = 3
    /// Buttons, text fields, chips, segmented controls.
    static let control: CGFloat = 9
    /// Rows and inner blocks that live inside a panel.
    static let row: CGFloat = 12
    /// Every panel and card on a page.
    static let panel: CGFloat = 20
    /// Floating surfaces: sheets, popovers, the lock gate, the inspector drawer.
    static let floating: CGFloat = 24
}

// MARK: - Spacing
//
// A single spacing scale, always multiplied through `RiverDensity` so compact
// mode stays coherent everywhere.

enum AppSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    /// Canonical inner padding of a panel.
    static let panelPadding: CGFloat = 18
    /// Canonical gap between two panels on the same page.
    static let panelGap: CGFloat = 18
    /// Gap between two groups of panels.
    static let sectionGap: CGFloat = 20
    /// Inset of a row divider so it lines up with row text, not the panel edge.
    static let dividerInset: CGFloat = 18
    static let controlHeight: CGFloat = 26
    static let rowHeight: CGFloat = 30
    static let page: CGFloat = 26
    static let reading: CGFloat = 14
    /// Breathing room between the window toolbar and a page header. Every page
    /// uses this so scrolling and fixed headers start at the same height.
    static let headerTop: CGFloat = 20
    /// Space between a page header (and its actions row) and the first panel.
    static let headerBottom: CGFloat = 16
}

enum AppMotion {
    static let quick: Double = 0.14
    static let standard: Double = 0.2
    static let calm: Double = 0.28
}

// MARK: - 入场动效
//
// A quiet fade-and-rise for stacked page sections. Runs once per view
// identity with a small stagger; Reduce Motion snaps straight to the final
// state.

struct RiverAppear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var index: Int = 0
    @State private var isAppeared = false

    func body(content: Content) -> some View {
        content
            .opacity(isAppeared ? 1 : 0)
            .offset(y: isAppeared ? 0 : 10)
            .onAppear {
                if reduceMotion {
                    isAppeared = true
                } else {
                    withAnimation(.easeOut(duration: AppMotion.calm).delay(Double(index) * 0.05)) {
                        isAppeared = true
                    }
                }
            }
    }
}

extension View {
    func riverAppear(index: Int = 0) -> some View { modifier(RiverAppear(index: index)) }
}

// MARK: - Typography
//
// A complete scale, so no view needs a raw `.system(size:)`. Sizes step by
// 1–2pt to keep dense evidence tables readable.

enum AppTypography {
    /// Page title, 22pt. One per page. Rounded numerals keep dates friendly.
    static func pageTitle(weight: Font.Weight = .semibold) -> Font {
        .system(size: 22, weight: weight, design: .rounded)
    }
    /// Emphasised page title (今日): one step larger, same rounded face.
    static func pageTitleLarge(weight: Font.Weight = .semibold) -> Font {
        .system(size: 26, weight: weight, design: .rounded)
    }
    /// Title of a sheet or a modal surface.
    static func sheetTitle() -> Font {
        .system(size: 17, weight: .semibold)
    }
    /// Title of a panel or a section.
    static func sectionTitle() -> Font {
        .system(size: 15, weight: .semibold)
    }
    /// Title of a row: dense but clearly above body text.
    static func rowTitle() -> Font {
        .system(size: 13, weight: .medium)
    }
    /// Primary reading text.
    static func primary() -> Font {
        .system(size: 14)
    }
    /// Secondary reading text and list bodies.
    static func secondary() -> Font {
        .system(size: 13)
    }
    /// Form labels and compact list text.
    static func label() -> Font {
        .system(size: 12)
    }
    /// Metadata / captions.
    static func metadata() -> Font {
        .system(size: 11)
    }
    /// The smallest text the app allows: dense counters and inline hints.
    static func micro() -> Font {
        .system(size: 10)
    }
    /// Timeline clocks, durations, counts.
    static func numeric() -> Font {
        .system(size: 12, weight: .semibold).monospacedDigit()
    }
    /// Inline metric inside a panel.
    static func metricSmall() -> Font {
        .system(size: 18, weight: .semibold, design: .rounded).monospacedDigit()
    }
    /// The single large number of a page.
    static func metric() -> Font {
        .system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()
    }
    /// The hero number of the 今日 dashboard: one step above `metric`.
    static func metricDisplay() -> Font {
        .system(size: 30, weight: .semibold, design: .rounded).monospacedDigit()
    }
    /// Raw data, file names, run IDs, evidence metadata.
    static func mono() -> Font {
        .system(size: 11, design: .monospaced)
    }
    /// Small uppercase monospaced kicker.
    static func kicker() -> Font {
        .system(size: 10, weight: .semibold, design: .monospaced)
    }
    static func reportTitle() -> Font {
        .system(size: 28, weight: .semibold, design: .rounded)
    }
    static func reportMetric() -> Font {
        .system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()
    }
}

// MARK: - Surfaces

/// How much a surface floats above the page. Elevation is reserved for surfaces
/// that genuinely sit on top of other content; inline panels stay flat.
enum AppSurfaceLevel {
    /// Sits inside a scrolling page column.
    case page
    /// A panel on the page canvas.
    case panel
    /// A panel on a panel (nested groups, toolbars).
    case raised
    /// Sheets, popovers, drawers, the lock gate.
    case overlay
}
