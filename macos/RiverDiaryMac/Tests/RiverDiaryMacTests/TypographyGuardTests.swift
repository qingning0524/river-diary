import XCTest

@testable import RiverDiaryMac

/// 设计系统守卫：`DESIGN.md` 规定视图里的裸 `.system(size:)` 只保留给
/// 图标字形（`Image(systemName:)`），绝不用于文字。
///
/// 这条规则在 2026-09-25 靠人工巡检清扫过一次，说明它会复发。这里把它变成
/// 一条会失败的测试：新增的文字裸字号会立刻被拦住，而不是等下一个人肉眼发现。
final class TypographyGuardTests: XCTestCase {

    private static let viewsDirectory = "Sources/RiverDiaryMac/Views"

    /// 允许带裸字号的组件：图标字形。
    private static let iconCallPattern = #"Image\(\s*systemName:"#

    private func viewSources() throws -> [(path: String, text: String)] {
        // 测试进程的工作目录是包根（macos/RiverDiaryMac），SwiftPM 不给测试提供
        // `#filePath` 以外的方式定位源码树，因此按包根相对路径读取。
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = root.appendingPathComponent(Self.viewsDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            throw XCTSkip("找不到 Views 目录：\(directory.path)")
        }

        var sources: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            sources.append((url.path, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertFalse(sources.isEmpty, "Views 目录里没有读到任何 Swift 文件")
        return sources
    }

    /// 判断某个 `.font(.system(size:` 出现位置是否属于图标字形。
    ///
    /// 视图里常见两种写法：
    /// - `Image(systemName: x).font(.system(size: 12))` —— 同一句内，合法；
    /// - `Image(systemName: x)` 换行后 `.font(.system(size: 12))` —— 合法；
    /// 反过来 `Text("…").font(.system(size: 13))` 必须失败。
    /// 这里向后回看 200 个字符，覆盖多行修饰符链。
    private func isIconFont(sizeRange: Range<String.Index>, in text: String) -> Bool {
        let window = max(0, text.distance(from: text.startIndex, to: sizeRange.lowerBound) - 200)
        let start = text.index(text.startIndex, offsetBy: window)
        let prefix = String(text[start..<sizeRange.lowerBound])
        return prefix.range(of: Self.iconCallPattern, options: .regularExpression) != nil
    }

    func testBareSystemFontSizeIsOnlyUsedForIconGlyphs() throws {
        let pattern = #"\.font\(\s*\.system\(size:"#
        var offences: [String] = []

        for (path, text) in try viewSources() {
            let regex = try NSRegularExpression(pattern: pattern)
            let full = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: full) {
                guard let range = Range(match.range, in: text) else { continue }
                guard !isIconFont(sizeRange: range, in: text) else { continue }
                let line = text[text.startIndex..<range.lowerBound]
                    .filter { $0 == "\n" }.count + 1
                let relative = path.components(separatedBy: "Sources/RiverDiaryMac/").last ?? path
                offences.append("\(relative):\(line)")
            }
        }

        XCTAssertTrue(
            offences.isEmpty,
            """
            以下位置把裸 .system(size:) 用在文字上，违反 DESIGN.md 的字号规范。
            请改用 AppTypography 的 token（primary/secondary/rowTitle/label/metadata/micro/numeric）：
            \(offences.joined(separator: "\n"))
            """
        )
    }

    func testBreakpointMatchesTheDefaultWindowWidth() {
        // Inspector 分流阈值必须 ≤ 默认窗口宽度，否则开箱即用的形态
        // 永远是窄窗浮层这一降级形态，而不是设计基准里的并排布局。
        XCTAssertLessThanOrEqual(
            AppLayout.sideInspectorBreakpoint,
            1280,
            "sideInspectorBreakpoint 高于默认窗口宽度，默认打开时右侧详情会退化成浮层"
        )
    }
}
