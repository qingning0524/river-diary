import Combine
import Foundation
import SwiftUI

enum RiverThemeID: String, CaseIterable, Codable, Identifiable {
    case clearLife = "clear_life"
    case contemporaryJournal = "contemporary_journal"
    case nightDashboard = "night_dashboard"
    var id: String { rawValue }
    var order: Int { Self.allCases.firstIndex(of: self)! }
    var name: String { switch self { case .clearLife: "柔光拟态"; case .contemporaryJournal: "当代手记"; case .nightDashboard: "夜色仪表" } }
    var summary: String { switch self { case .clearLife: "同一束柔光，细腻呈现生活。"; case .contemporaryJournal: "像翻开一本手记，慢慢读回生活。"; case .nightDashboard: "深色、精确、安静。" } }
    var symbol: String { switch self { case .clearLife: "sun.max"; case .contemporaryJournal: "book.closed"; case .nightDashboard: "moon.stars" } }
    var colorScheme: ColorScheme { self == .nightDashboard ? .dark : .light }
}

private struct RiverThemePreferences: Codable, Equatable {
    var schemaVersion = 2
    var themeID: String = RiverThemeID.clearLife.rawValue
    var selectedTheme: RiverThemeID { RiverThemeID(rawValue: themeID) ?? .clearLife }
}

/// One palette per style. Status colours follow the evidence language:
/// a tinted soft field carries the pill, the strong colour carries text/icons,
/// and the word always carries the meaning (colour is the second channel).
struct RiverThemePalette {
    let canvas: Color
    let surface: Color
    let raisedSurface: Color
    let ink: Color
    let secondaryInk: Color
    let accent: Color
    let onAccent: Color
    let separator: Color
    let accentSoft: Color
    let riverSurface: Color
    let placeSurface: Color
    let noteSurface: Color
    let success: Color
    let successSoft: Color
    let warning: Color
    let warningSoft: Color
    let danger: Color
    let dangerSoft: Color
    let washTop: Color
    let washBottom: Color

    init(hex: [String]) {
        func color(_ index: Int) -> Color { Color(hex: hex[index]) }
        canvas = color(0); surface = color(1); raisedSurface = color(2); ink = color(3); secondaryInk = color(4)
        accent = color(5); onAccent = color(6); separator = color(7); accentSoft = color(8); riverSurface = color(9)
        placeSurface = color(10); noteSurface = color(11)
        success = color(12); successSoft = color(13); warning = color(14); warningSoft = color(15)
        danger = color(16); dangerSoft = color(17); washTop = color(18); washBottom = color(19)
    }

    static func colors(for id: RiverThemeID, appearance: ColorScheme) -> Self {
        switch id {
        case .clearLife:
            Self(hex: ["#EEF2F6", "#EEF2F6", "#E8EEF5", "#1E293B", "#64748B", "#2563EB", "#FFFFFF", "#DAE2ED", "#EFF6FF", "#EEF2F6", "#ECFDF5", "#EEF2F6",
                       "#059669", "#ECFDF5", "#B45309", "#FFFBEB", "#B35353", "#F4E7E7", "#EEF2F6", "#EEF2F6"])
        case .contemporaryJournal:
            Self(hex: ["#F8F5EF", "#FFFDFA", "#EEEAE2", "#302F29", "#716B60", "#52634B", "#FFFFFF", "#DED9CE", "#EAEEDF", "#F2F3E9", "#F2F3E9", "#FFFDFA",
                       "#3F6B4C", "#E7EEDF", "#8F651C", "#F4EBD7", "#A84134", "#F6E4DF", "#F8F5EF", "#F8F5EF"])
        case .nightDashboard:
            Self(hex: ["#13221F", "#1B2C27", "#263A32", "#ECF1EA", "#ABBEB3", "#9AD1B9", "#162B22", "#3A4F43", "#294437", "#1D3229", "#1D3229", "#1B2C27",
                       "#9AD1B9", "#294437", "#E5BC70", "#3C3220", "#EF9B8D", "#422C26", "#13221F", "#13221F"])
        }
    }
}

struct RiverThemeContext {
    let id: RiverThemeID
    let palette: RiverThemePalette
    let colorScheme: ColorScheme
    init(id: RiverThemeID, colorScheme: ColorScheme) {
        self.id = id; self.colorScheme = id.colorScheme; self.palette = .colors(for: id, appearance: id.colorScheme)
    }
    var canvas: Color { palette.canvas }; var surface: Color { palette.surface }; var raisedSurface: Color { palette.raisedSurface }
    var ink: Color { palette.ink }; var secondaryInk: Color { palette.secondaryInk }; var accent: Color { palette.accent }; var accentText: Color { palette.accent }
    var accentSoft: Color { palette.accentSoft }; var separator: Color { palette.separator }; var riverSurface: Color { palette.riverSurface }; var placeSurface: Color { palette.placeSurface }; var noteSurface: Color { palette.noteSurface }
    var success: Color { palette.success }; var successSoft: Color { palette.successSoft }
    var warning: Color { palette.warning }; var warningSoft: Color { palette.warningSoft }
    var danger: Color { palette.danger }; var dangerSoft: Color { palette.dangerSoft }
    var pageGutter: CGFloat { 20 }; var timelineGutter: CGFloat { 20 }; var footprintGutter: CGFloat { 16 }; var sectionSpacing: CGFloat { 24 }
    var panelRadius: CGFloat { id == .contemporaryJournal ? 16 : 24 }; var mapRadius: CGFloat { 16 }; var tapTarget: CGFloat { 44 }; var footprintMapHeight: CGFloat { 220 }; var storyRadius: CGFloat { panelRadius }
    var chipRadius: CGFloat { id == .contemporaryJournal ? 9 : 12 }
    func textFont(_ size: CGFloat, relativeTo style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        .custom("PingFangSC-Regular", size: size, relativeTo: style).weight(weight)
    }
    var titleFont: Font { .system(.title, design: .rounded).weight(.bold) }
    var displayFont: Font { id == .nightDashboard ? .custom("Menlo-Regular", size: 26, relativeTo: .title) : textFont(26, relativeTo: .title, weight: .medium) }
    var sectionFont: Font { textFont(18, relativeTo: .headline, weight: .semibold) }
    var bodyFont: Font { .body }; var detailFont: Font { .callout }; var captionFont: Font { .footnote }
    var editorialRules: Bool { id == .contemporaryJournal }; var flatSurfaces: Bool { id == .contemporaryJournal }; var borderWidth: CGFloat { id == .contemporaryJournal ? 0 : 0.5 }; var surfaceShadow: Double { 0 }
    /// Soft vertical wash for hero bands (Today header, River intro, login).
    /// It is a background breath, never a decorative banner: both stops stay
    /// inside the palette family so text over it keeps full contrast.
    var heroWash: LinearGradient {
        LinearGradient(colors: [palette.washTop, palette.washBottom], startPoint: .top, endPoint: .bottom)
    }
    /// Elevation for the few things that genuinely float (floating bars, orbs).
    var floatingShadow: RiverShadow { RiverShadow(
        color: colorScheme == .dark ? .black.opacity(0.32) : palette.ink.opacity(0.10),
        radius: 18, y: 8
    ) }
}

struct RiverShadow {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
    init(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat) {
        self.color = color; self.radius = radius; self.x = x; self.y = y
    }
}

private struct RiverThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = RiverThemeContext(id: .clearLife, colorScheme: .light)
}
extension EnvironmentValues {
    var riverTheme: RiverThemeContext { get { self[RiverThemeEnvironmentKey.self] } set { self[RiverThemeEnvironmentKey.self] = newValue } }
}

@MainActor
final class RiverThemeStore: ObservableObject {
    static let preferenceKey = "river.theme.preferences.v2"
    static let legacyPreferenceKey = "river.theme.preferences.v1"
    private let defaults: UserDefaults
    @Published private var preferences: RiverThemePreferences
    @Published private(set) var errorMessage: String?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Only v2 identifiers can restore a style. Legacy themes all migrate to A.
        if let data = defaults.data(forKey: Self.preferenceKey), let value = try? JSONDecoder().decode(RiverThemePreferences.self, from: data), RiverThemeID(rawValue: value.themeID) != nil {
            preferences = value
        } else {
            preferences = RiverThemePreferences()
            if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.preferenceKey) }
        }
    }
    var selectedThemeID: RiverThemeID { preferences.selectedTheme }
    var selectedThemeName: String { selectedThemeID.name }
    var selectedThemeSummary: String { selectedThemeID.summary }
    var preferredColorScheme: ColorScheme? { selectedThemeID.colorScheme }
    func context(for colorScheme: ColorScheme) -> RiverThemeContext { RiverThemeContext(id: selectedThemeID, colorScheme: colorScheme) }
    func previewContext(for themeID: RiverThemeID, colorScheme: ColorScheme) -> RiverThemeContext { RiverThemeContext(id: themeID, colorScheme: colorScheme) }
    @discardableResult
    func applyTheme(_ id: RiverThemeID) -> Bool {
        guard id != selectedThemeID else { return false }
        var value = preferences
        value.themeID = id.rawValue
        guard let data = try? JSONEncoder().encode(value) else { errorMessage = "外观偏好暂时无法保存，请重试。"; return false }
        defaults.set(data, forKey: Self.preferenceKey)
        guard defaults.data(forKey: Self.preferenceKey) == data else { errorMessage = "外观偏好暂时无法保存，请重试。"; return false }
        preferences = value
        errorMessage = nil
        return true
    }
}
