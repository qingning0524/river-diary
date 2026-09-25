import XCTest
@testable import RiverDiaryMac

/// 面板内边距的守卫。
///
/// `RiverPanel` 里如果直接写 `content().padding(...)`，`content` 是 ViewBuilder 产出的
/// 多元组，SwiftUI 会把内边距**分给每一个子视图**：每个面板行都多出上下各 18pt，
/// 行距从 47pt 变成 83pt。像素实测（面板分隔线间距）确认过这个翻倍。
/// 正确写法是先把 `content()` 收进一个 VStack，再给那个 VStack 加内边距。
final class PanelLayoutTests: XCTestCase {

    private func panelsSource() throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/RiverDiaryMac/Views/Panels.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testPanelPaddingIsAppliedOnceInsteadOfPerRow() throws {
        let text = try panelsSource()
        guard let start = text.range(of: "struct RiverPanel<Header: View, Content: View>"),
              let end = text.range(of: "extension RiverPanel where Header == RiverPanelTitle") else {
            return XCTFail("找不到 RiverPanel 定义")
        }
        let body = String(text[start.lowerBound..<end.lowerBound])
        // 先去掉注释行：注释里正好引用了那个错误写法，否则测试会误报。
        let code = body
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let compact = code
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")

        XCTAssertFalse(
            compact.contains("content().padding("),
            "RiverPanel 直接把内边距加在 content() 上：ViewBuilder 多元组会把内边距分给每一行，行距翻倍"
        )
        XCTAssertTrue(
            compact.contains("VStack(alignment:.leading,spacing:0){content()}"),
            "RiverPanel 需要先把 content() 收进 VStack，内边距才会只作用一次"
        )
    }
}
