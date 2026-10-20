import AppKit
import XCTest
@testable import RiverDiaryMac

/// T02：未登录/退出后 Dock 菜单不能再出现写入与采集入口。
@MainActor
final class MenuGateTests: XCTestCase {
    override func tearDown() {
        AccountMenuPresence.isSignedIn = false
        super.tearDown()
    }

    func testDockMenuHidesCaptureEntriesWhenSignedOut() {
        let delegate = AppDelegate()

        AccountMenuPresence.isSignedIn = false
        let signedOut = delegate.applicationDockMenu(NSApplication.shared)
        XCTAssertEqual(signedOut?.items.map(\.title), ["打开河流日记"])

        AccountMenuPresence.isSignedIn = true
        let signedIn = delegate.applicationDockMenu(NSApplication.shared)
        XCTAssertEqual(signedIn?.items.map(\.title), ["打开河流日记", "写一句…", "立即采集一次"])
    }
}
