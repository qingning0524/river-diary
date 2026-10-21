import AppKit
import XCTest
@testable import RiverDiaryMac

/// v5.0：Dock 菜单跟随“本机资料已就绪”，不再跟随账号登录态。
@MainActor
final class MenuGateTests: XCTestCase {
    override func tearDown() {
        AccountMenuPresence.isLibraryReady = false
        super.tearDown()
    }

    func testDockMenuFollowsLocalLibraryReady() {
        let delegate = AppDelegate()

        AccountMenuPresence.isLibraryReady = false
        let notReady = delegate.applicationDockMenu(NSApplication.shared)
        XCTAssertEqual(notReady?.items.map(\.title), ["打开河流日记"])

        AccountMenuPresence.isLibraryReady = true
        let ready = delegate.applicationDockMenu(NSApplication.shared)
        XCTAssertEqual(ready?.items.map(\.title), ["打开河流日记", "写一句…", "立即采集一次"])
    }
}
