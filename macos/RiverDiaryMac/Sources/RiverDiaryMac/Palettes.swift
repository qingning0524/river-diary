import SwiftUI

// MARK: - 配色方案
//
// 八套完整主题（浅色 + 深色）。中性色画布随配色微调色相，状态色（正常/警示/错误）
// 保持全局统一。用户在 设置 · 外观 里切换，选择立即生效并持久化。

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
                    canvas: "#F0F3F8", sidebar: "#F7FAFD", surface: "#FFFFFF", strongSurface: "#FFFFFF",
                    editor: "#F1F4F9", chip: "#F0F3F8",
                    border: "#EAEFF4", separator: "#F1F4F8", strongSeparator: "#DDE4EC",
                    ink: "#1B2330", ink2: "#5C6776", ink3: "#94A0B0",
                    accent: "#3E74DC", accentSoft: "#E8EFFD",
                    gradientStart: "#4C80E8", gradientEnd: "#3E9BD6"
                ),
                dark: .init(
                    canvas: "#0D111C", sidebar: "#141A28", surface: "#151B2A", strongSurface: "#1C2436",
                    editor: "#0F1420", chip: "#1B2336",
                    border: "#FFFFFF", separator: "#FFFFFF", strongSeparator: "#2A3346",
                    ink: "#E9EDF5", ink2: "#9AA6B8", ink3: "#67738A",
                    accent: "#6FA0FF", accentSoft: "#1C2A4A",
                    gradientStart: "#5D8BE8", gradientEnd: "#4E9EDD"
                )
            )
        case .celadon:
            return RiverPaletteTheme(
                light: .init(
                    canvas: "#EDF3F0", sidebar: "#F4F9F6", surface: "#FFFFFF", strongSurface: "#FFFFFF",
                    editor: "#E8F0EC", chip: "#E7EFEB",
                    border: "#DFE9E4", separator: "#EAF0EC", strongSeparator: "#CFE0D8",
                    ink: "#1A2622", ink2: "#576962", ink3: "#8C9C94",
                    accent: "#23A183", accentSoft: "#DFF3ED",
                    gradientStart: "#2BB893", gradientEnd: "#35C2AE"
                ),
                dark: .init(
                    canvas: "#0B1210", sidebar: "#101917", surface: "#121A17", strongSurface: "#182320",
                    editor: "#0E1513", chip: "#1A2521",
                    border: "#FFFFFF", separator: "#FFFFFF", strongSeparator: "#22332C",
                    ink: "#E7F0EC", ink2: "#97A8A0", ink3: "#66766F",
                    accent: "#4ECDAF", accentSoft: "#11302A",
                    gradientStart: "#3BBD9B", gradientEnd: "#3FC7B4"
                )
            )
        case .sunrise:
            return RiverPaletteTheme(
                light: .init(
                    canvas: "#F6F1EA", sidebar: "#FAF6F0", surface: "#FFFFFF", strongSurface: "#FFFFFF",
                    editor: "#F0E8DD", chip: "#F1E9DE",
                    border: "#EAE1D4", separator: "#F2EBE1", strongSeparator: "#E0D4C2",
                    ink: "#27201A", ink2: "#6E6357", ink3: "#A39688",
                    accent: "#D0701F", accentSoft: "#FAE8D6",
                    gradientStart: "#E58B3F", gradientEnd: "#DE6440"
                ),
                dark: .init(
                    canvas: "#141009", sidebar: "#1D1710", surface: "#1D1710", strongSurface: "#251D14",
                    editor: "#171209", chip: "#262017",
                    border: "#FFFFFF", separator: "#FFFFFF", strongSeparator: "#332A1E",
                    ink: "#F2EBE2", ink2: "#AFA394", ink3: "#7B7164",
                    accent: "#F09A55", accentSoft: "#33230E",
                    gradientStart: "#E89A55", gradientEnd: "#E0714A"
                )
            )
        case .iris:
            return RiverPaletteTheme(
                light: .init(
                    canvas: "#F0EFF7", sidebar: "#F5F4FA", surface: "#FFFFFF", strongSurface: "#FFFFFF",
                    editor: "#EAE8F3", chip: "#EBE9F4",
                    border: "#E3E1EF", separator: "#EEEDF5", strongSeparator: "#D9D6EA",
                    ink: "#211F2E", ink2: "#635F78", ink3: "#9894AB",
                    accent: "#6F63E6", accentSoft: "#EAE8FC",
                    gradientStart: "#8377EE", gradientEnd: "#6A60DF"
                ),
                dark: .init(
                    canvas: "#0F0E16", sidebar: "#16151F", surface: "#16151F", strongSurface: "#1D1C28",
                    editor: "#121118", chip: "#1D1C29",
                    border: "#FFFFFF", separator: "#FFFFFF", strongSeparator: "#2A2840",
                    ink: "#ECEAF5", ink2: "#A29EB5", ink3: "#6F6B84",
                    accent: "#9C92F2", accentSoft: "#25224A",
                    gradientStart: "#968CF2", gradientEnd: "#7E74E8"
                )
            )
        case .berry:
            return RiverPaletteTheme(
                light: .init(
                    canvas: "#F7F1F3", sidebar: "#FAF5F6", surface: "#FFFFFF", strongSurface: "#FFFFFF",
                    editor: "#F1E7EA", chip: "#F2E8EB",
                    border: "#EFE1E5", separator: "#F4EAED", strongSeparator: "#E8D5DB",
                    ink: "#2A1E23", ink2: "#6F5B62", ink3: "#A39198",
                    accent: "#D5537B", accentSoft: "#FBE3EB",
                    gradientStart: "#E3698D", gradientEnd: "#D84E77"
                ),
                dark: .init(
                    canvas: "#150F11", sidebar: "#1D1517", surface: "#1D1517", strongSurface: "#251B1E",
                    editor: "#181013", chip: "#271C1F",
                    border: "#FFFFFF", separator: "#FFFFFF", strongSeparator: "#38242B",
                    ink: "#F2E9EC", ink2: "#B09DA4", ink3: "#7E6C73",
                    accent: "#F2819F", accentSoft: "#3A1E28",
                    gradientStart: "#EE85A5", gradientEnd: "#DE6086"
                )
            )
        case .moke:
            return RiverPaletteTheme(
                light: .init(
                    canvas: "#EDF0F4", sidebar: "#F4F7FA", surface: "#FFFFFF", strongSurface: "#FFFFFF",
                    editor: "#E8ECF1", chip: "#E9EDF2",
                    border: "#DFE5EC", separator: "#EBEFF4", strongSeparator: "#D4DCE5",
                    ink: "#1D242D", ink2: "#5A6470", ink3: "#939CA8",
                    accent: "#47618B", accentSoft: "#E4EAF2",
                    gradientStart: "#5D7FA9", gradientEnd: "#41608A"
                ),
                dark: .init(
                    canvas: "#0D1013", sidebar: "#14181D", surface: "#14181D", strongSurface: "#1B2129",
                    editor: "#0F1317", chip: "#1B2129",
                    border: "#FFFFFF", separator: "#FFFFFF", strongSeparator: "#262E38",
                    ink: "#E9EDF2", ink2: "#9BA5B0", ink3: "#6B7580",
                    accent: "#7FA0C9", accentSoft: "#1F2C3D",
                    gradientStart: "#7295BD", gradientEnd: "#5F7FA9"
                )
            )
        case .cocoa:
            return RiverPaletteTheme(
                light: .init(
                    canvas: "#F4F0EA", sidebar: "#F9F5EF", surface: "#FFFFFF", strongSurface: "#FFFFFF",
                    editor: "#EFE9E0", chip: "#F0EAE1",
                    border: "#E7DFD3", separator: "#F1EBE2", strongSeparator: "#DDD2C2",
                    ink: "#26201A", ink2: "#6B6156", ink3: "#A29788",
                    accent: "#A9713C", accentSoft: "#F5E9DC",
                    gradientStart: "#C08552", gradientEnd: "#A96A38"
                ),
                dark: .init(
                    canvas: "#131009", sidebar: "#1B1710", surface: "#1B1610", strongSurface: "#241D14",
                    editor: "#171209", chip: "#262017",
                    border: "#FFFFFF", separator: "#FFFFFF", strongSeparator: "#352C1F",
                    ink: "#F2ECE2", ink2: "#ACA196", ink3: "#7D7365",
                    accent: "#D89A5F", accentSoft: "#33240F",
                    gradientStart: "#CE9155", gradientEnd: "#B87B41"
                )
            )
        case .blossom:
            return RiverPaletteTheme(
                light: .init(
                    canvas: "#F8F2F5", sidebar: "#FBF6F8", surface: "#FFFFFF", strongSurface: "#FFFFFF",
                    editor: "#F4EAEE", chip: "#F4EBEF",
                    border: "#F0E3E9", separator: "#F6EEF1", strongSeparator: "#EBD8E0",
                    ink: "#2B2026", ink2: "#75606B", ink3: "#A895A0",
                    accent: "#DB6E9C", accentSoft: "#FBE7F0",
                    gradientStart: "#EE8CB4", gradientEnd: "#E0679E"
                ),
                dark: .init(
                    canvas: "#150F13", sidebar: "#1D1519", surface: "#1D1519", strongSurface: "#251B20",
                    editor: "#180F14", chip: "#271D22",
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
        // 双保险：Shell 以配色为身份重建整棵子树；这里再请 AppKit 对所有可见
        // 窗口强制重绘一次，确保任何被 SwiftUI 跳过 body 的视图也立即重解析。
        DispatchQueue.main.async {
            for window in NSApp.windows where window.isVisible {
                window.contentView?.needsDisplay = true
            }
        }
    }
}
