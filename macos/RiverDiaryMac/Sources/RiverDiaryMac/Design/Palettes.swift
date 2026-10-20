import SwiftUI

// MARK: - 配色方案
//
// 八套完整主题（浅色 + 深色）。中性色画布随配色微调色相，状态色（正常/警示/错误）
// 保持全局统一。用户在 设置 · 外观 里切换，选择立即生效并持久化。
//
// ## 景深色阶（2026-09-26 重算）
//
// 原表的柔和水洗色彼此只差 1.04–1.16 个对比度档：浅色下 seafoam 的面板描边
// `#EAEFF4` 压在画布 `#F0F3F8` 上只有 1.04:1，深色下的行分隔线（白 4.5% 压进面板）
// 只有 1.009:1——等于没画。整页因此显得平、像未完成，而不是"柔和"。
//
// 现在每个值都由下面的配方生成，八套配色 × 明暗同构（保留原本的色相与彩度比例，
// 只把"明度台阶"拉到可感知区间）：
//
//   令牌              浅色（对白色/画布）      深色（对面板底）
//   canvas            白 → 1.17                面板 → 1.10（更深）
//   border            画布 → 1.26              白 10%（darkBorderAlpha）
//   separator         白 → 1.20                白 8%（darkSeparatorAlpha）
//   strongSeparator   画布 → 1.40              面板 → 1.30
//   chip              白 → 1.15                面板 → 1.15
//   editor            白 → 1.14                面板 → 1.07（更深）
//   strongSurface     白                       面板 → 1.13
//   sidebar           画布 → 1.07              画布 → 1.07
//   ink3              白 → 3.25                原值（约 3.6）
//
// `PaletteDepthTests` 逐套配色把这张表钉住：任何一格掉回"看不见"都会失败。
// 调整色值请连同 DESIGN.md 的色阶表和那条测试一起改。

struct RiverPaletteColorSet {
    let canvas: String
    let sidebar: String
    let surface: String
    let strongSurface: String
    let editor: String
    let chip: String
    let border: String
    let separator: String
    let strongSeparator: String
    let ink: String
    let ink2: String
    let ink3: String
    let accent: String
    let accentSoft: String
    let gradientStart: String
    let gradientEnd: String
}

struct RiverPaletteTheme {
    let light: RiverPaletteColorSet
    let dark: RiverPaletteColorSet
}

enum RiverPalette: String, CaseIterable, Identifiable {
    case seafoam   // 海雾蓝（默认）
    case celadon   // 青瓷
    case sunrise   // 暖阳
    case iris      // 堇紫
    case berry     // 莓红
    case moke      // 墨青
    case cocoa     // 可可棕
    case blossom   // 樱花粉

    var id: String { rawValue }

    var title: String {
        switch self {
        case .seafoam: "海雾蓝"
        case .celadon: "青瓷"
        case .sunrise: "暖阳"
        case .iris: "堇紫"
        case .berry: "莓红"
        case .moke: "墨青"
        case .cocoa: "可可棕"
        case .blossom: "樱花粉"
        }
    }

    /// 每套配色的第一印象，用于设置里的说明。
    var tagline: String {
        switch self {
        case .seafoam: "冷静 · 可信 · 工具感"
        case .celadon: "河流与草木的气息"
        case .sunrise: "清晨的第一杯茶"
        case .iris: "柔和的想象力"
        case .berry: "纸页间的一点胭脂"
        case .moke: "仪器般的沉稳钢青"
        case .cocoa: "旧书页与咖啡的暖意"
        case .blossom: "三月的樱花"
        }
    }

    var theme: RiverPaletteTheme {
        switch self {
        case .seafoam:
            return RiverPaletteTheme(
                light: .init(
                    canvas: "#EDF1F6", sidebar: "#E8EDF3", surface: "#EDF2F7", strongSurface: "#F3F6FA",
                    editor: "#EAF0F6", chip: "#E4EBF4",
                    border: "#D5DFEC", separator: "#D9E1EC", strongSeparator: "#C5D2E2",
                    ink: "#28364B", ink2: "#5D6E86", ink3: "#7C8CA3",
                    accent: "#2F6CF5", accentSoft: "#E0EAFF",
                    gradientStart: "#2F6CF5", gradientEnd: "#2F6CF5"
                ),
                dark: .init(
                    canvas: "#202935", sidebar: "#1C2530", surface: "#25303D", strongSurface: "#2B3747",
                    editor: "#202B38", chip: "#2D3A4B",
                    border: "#3B495C", separator: "#3B495C", strongSeparator: "#4B5A70",
                    ink: "#E0E8F4", ink2: "#A4B3C8", ink3: "#91A2BA",
                    accent: "#7FAAFF", accentSoft: "#2B4166",
                    gradientStart: "#4B83F6", gradientEnd: "#326BE8"
                )
            )
        case .celadon:
            return RiverPaletteTheme(
                light: .init(
                    canvas: "#E9EFEC", sidebar: "#F4F9F6", surface: "#FFFFFF", strongSurface: "#FFFFFF",
                    editor: "#E2EAE6", chip: "#E9F1ED",
                    border: "#CED7D3", separator: "#E6ECE8", strongSeparator: "#BECEC7",
                    ink: "#1A2622", ink2: "#576962", ink3: "#83928B",
                    accent: "#23A183", accentSoft: "#DFF3ED",
                    gradientStart: "#2BB893", gradientEnd: "#35C2AE"
                ),
                dark: .init(
                    canvas: "#080E0C", sidebar: "#0F1715", surface: "#121A17", strongSurface: "#1A2622",
                    editor: "#0C1210", chip: "#1C2723",
                    border: "#FFFFFF", separator: "#FFFFFF", strongSeparator: "#21312A",
                    ink: "#E7F0EC", ink2: "#97A8A0", ink3: "#66766F",
                    accent: "#4ECDAF", accentSoft: "#11302A",
                    gradientStart: "#3BBD9B", gradientEnd: "#3FC7B4"
                )
            )
        case .sunrise:
            return RiverPaletteTheme(
                light: .init(
                    canvas: "#F1ECE6", sidebar: "#FAF6F0", surface: "#FFFFFF", strongSurface: "#FFFFFF",
                    editor: "#EFE7DC", chip: "#F6EEE3",
                    border: "#DCD3C7", separator: "#F0E9E0", strongSeparator: "#D4C8B7",
                    ink: "#27201A", ink2: "#6E6357", ink3: "#998D80",
                    accent: "#D0701F", accentSoft: "#FAE8D6",
                    gradientStart: "#E58B3F", gradientEnd: "#DE6440"
                ),
                dark: .init(
                    canvas: "#0F0C06", sidebar: "#1A140E", surface: "#1D1710", strongSurface: "#2A2218",
                    editor: "#141007", chip: "#2A241A",
                    border: "#FFFFFF", separator: "#FFFFFF", strongSeparator: "#352C20",
                    ink: "#F2EBE2", ink2: "#AFA394", ink3: "#7B7164",
                    accent: "#F09A55", accentSoft: "#33230E",
                    gradientStart: "#E89A55", gradientEnd: "#E0714A"
                )
            )
        case .iris:
            return RiverPaletteTheme(
                light: .init(
                    canvas: "#EDECF4", sidebar: "#F5F4FA", surface: "#FFFFFF", strongSurface: "#FFFFFF",
                    editor: "#E9E7F2", chip: "#F0EEF9",
                    border: "#D5D3E0", separator: "#EAE9F1", strongSeparator: "#CBC8DB",
                    ink: "#211F2E", ink2: "#635F78", ink3: "#908CA2",
                    accent: "#6F63E6", accentSoft: "#EAE8FC",
                    gradientStart: "#8377EE", gradientEnd: "#6A60DF"
                ),
                dark: .init(
                    canvas: "#09080F", sidebar: "#13121B", surface: "#16151F", strongSurface: "#21202D",
                    editor: "#0E0D13", chip: "#232130",
                    border: "#FFFFFF", separator: "#FFFFFF", strongSeparator: "#2C2A42",
                    ink: "#ECEAF5", ink2: "#A29EB5", ink3: "#6F6B84",
                    accent: "#9C92F2", accentSoft: "#25224A",
                    gradientStart: "#968CF2", gradientEnd: "#7E74E8"
                )
            )
        case .berry:
            return RiverPaletteTheme(
                light: .init(
                    canvas: "#F2ECEE", sidebar: "#FAF5F6", surface: "#FFFFFF", strongSurface: "#FFFFFF",
                    editor: "#F0E6E9", chip: "#F7EDF0",
                    border: "#DFD2D5", separator: "#F2E8EB", strongSeparator: "#D8C6CC",
                    ink: "#2A1E23", ink2: "#6F5B62", ink3: "#9B8A91",
                    accent: "#D5537B", accentSoft: "#FBE3EB",
                    gradientStart: "#E3698D", gradientEnd: "#D84E77"
                ),
                dark: .init(
                    canvas: "#0E090B", sidebar: "#191214", surface: "#1D1517", strongSurface: "#2A1F23",
                    editor: "#140D10", chip: "#2D2124",
                    border: "#FFFFFF", separator: "#FFFFFF", strongSeparator: "#3C272E",
                    ink: "#F2E9EC", ink2: "#B09DA4", ink3: "#7E6C73",
                    accent: "#F2819F", accentSoft: "#3A1E28",
                    gradientStart: "#EE85A5", gradientEnd: "#DE6086"
                )
            )
        case .moke:
            return RiverPaletteTheme(
                light: .init(
                    canvas: "#EAEDF1", sidebar: "#F4F7FA", surface: "#FFFFFF", strongSurface: "#FFFFFF",
                    editor: "#E4E8EE", chip: "#EBEFF5",
                    border: "#CFD5DB", separator: "#E7EBF0", strongSeparator: "#C3CBD3",
                    ink: "#1D242D", ink2: "#5A6470", ink3: "#878F9B",
                    accent: "#47618B", accentSoft: "#E4EAF2",
                    gradientStart: "#5D7FA9", gradientEnd: "#41608A"
                ),
                dark: .init(
                    canvas: "#090C0F", sidebar: "#11151A", surface: "#14181D", strongSurface: "#1D232C",
                    editor: "#0C1014", chip: "#1E252D",
                    border: "#FFFFFF", separator: "#FFFFFF", strongSeparator: "#262E38",
                    ink: "#E9EDF2", ink2: "#9BA5B0", ink3: "#6B7580",
                    accent: "#7FA0C9", accentSoft: "#1F2C3D",
                    gradientStart: "#7295BD", gradientEnd: "#5F7FA9"
                )
            )
        case .cocoa:
            return RiverPaletteTheme(
                light: .init(
                    canvas: "#F1EDE7", sidebar: "#F9F5EF", surface: "#FFFFFF", strongSurface: "#FFFFFF",
                    editor: "#EDE7DE", chip: "#F4EEE5",
                    border: "#DCD4C9", separator: "#F0EAE1", strongSeparator: "#D4C9BA",
                    ink: "#26201A", ink2: "#6B6156", ink3: "#988D7F",
                    accent: "#A9713C", accentSoft: "#F5E9DC",
                    gradientStart: "#C08552", gradientEnd: "#A96A38"
                ),
                dark: .init(
                    canvas: "#0D0A05", sidebar: "#17130D", surface: "#1B1610", strongSurface: "#292117",
                    editor: "#120E07", chip: "#292319",
                    border: "#FFFFFF", separator: "#FFFFFF", strongSeparator: "#342B1F",
                    ink: "#F2ECE2", ink2: "#ACA196", ink3: "#7D7365",
                    accent: "#D89A5F", accentSoft: "#33240F",
                    gradientStart: "#CE9155", gradientEnd: "#B87B41"
                )
            )
        case .blossom:
            return RiverPaletteTheme(
                light: .init(
                    canvas: "#F1ECEF", sidebar: "#FBF6F8", surface: "#FFFFFF", strongSurface: "#FFFFFF",
                    editor: "#F0E5EA", chip: "#F6EDF1",
                    border: "#DED2D7", separator: "#F0E8EB", strongSeparator: "#D7C6CD",
                    ink: "#2B2026", ink2: "#75606B", ink3: "#9C8A94",
                    accent: "#DB6E9C", accentSoft: "#FBE7F0",
                    gradientStart: "#EE8CB4", gradientEnd: "#E0679E"
                ),
                dark: .init(
                    canvas: "#0E0A0D", sidebar: "#1A1216", surface: "#1D1519", strongSurface: "#2A1F25",
                    editor: "#150D11", chip: "#2C2126",
                    border: "#FFFFFF", separator: "#FFFFFF", strongSeparator: "#3A2833",
                    ink: "#F4EBEF", ink2: "#B39FAB", ink3: "#806E79",
                    accent: "#F191BB", accentSoft: "#3A2130",
                    gradientStart: "#F095BD", gradientEnd: "#E374A6"
                )
            )
        }
    }
}

// MARK: - 绘制时解析
//
// 颜色令牌在 Theme.swift 中以动态 NSColor 的形式缓存；这里的解析器在每次绘制时
// 读取当前配色，因此切换配色不需要重建视图树——只需触发一次重绘。

enum PaletteStore {
    static let defaultsKey = "appearance.palette"

    /// 主线程写、绘制线程读；切换频率极低，简单的静态变量即可。
    static var currentID: String = UserDefaults.standard.string(forKey: defaultsKey) ?? RiverPalette.seafoam.rawValue

    private static let cacheLock = NSLock()
    /// NSColor(hex:) 每次都要扫描字符串，而解析闭包在每一帧绘制里运行。
    /// 以 (paletteID, dark, 属性) 缓存解析结果；切换调色板时整体失效。
    /// 绘制可能发生在非主线程，读写都走锁（查表本身是纳秒级）。
    private static var resolvedCache: [String: NSColor] = [:]

    static func palette() -> RiverPalette {
        RiverPalette(rawValue: currentID) ?? .seafoam
    }

    static func colorSet(dark: Bool) -> RiverPaletteColorSet {
        let palette = RiverPalette(rawValue: currentID) ?? .seafoam
        return dark ? palette.theme.dark : palette.theme.light
    }

    static func colorSet(for appearance: NSAppearance) -> RiverPaletteColorSet {
        colorSet(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    /// 解析并缓存一个调色板颜色的 NSColor。
    static func resolvedColor(_ keyPath: KeyPath<RiverPaletteColorSet, String>, dark: Bool) -> NSColor {
        let key = "\(currentID)|\(dark ? "d" : "l")|\(keyPath)"
        cacheLock.lock()
        if let cached = resolvedCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let color = NSColor(hex: colorSet(dark: dark)[keyPath: keyPath])

        cacheLock.lock()
        resolvedCache[key] = color
        cacheLock.unlock()
        return color
    }

    static func invalidateResolvedColors() {
        cacheLock.lock()
        resolvedCache.removeAll()
        cacheLock.unlock()
    }
}

@MainActor
final class PaletteController: ObservableObject {
    static let shared = PaletteController()

    @Published private(set) var palette: RiverPalette = PaletteStore.palette()

    func select(_ palette: RiverPalette) {
        guard palette != self.palette else { return }
        PaletteStore.currentID = palette.rawValue
        PaletteStore.invalidateResolvedColors()
        UserDefaults.standard.set(palette.rawValue, forKey: PaletteStore.defaultsKey)
        self.palette = palette
        // 这里刻意**不做**强制重绘：实测 `needsDisplay`、`layer.setNeedsDisplay`、
        // `displayIfNeeded` 都不会让 SwiftUI 重新解析调色板颜色 —— SwiftUI 把已解析的
        // 颜色缓存住了，只有改变视图身份（`.id`）才会重新解析。
        // 因此两个窗口的根视图 body 都带 `.id(palette)`，而上面这行 `@Published`
        // 负责触发那次 body 重算。画在窗口上的 AppKit 静态色（窗口底色）由持有它的
        // 视图在 `updateNSView` 里同步。
    }
}
