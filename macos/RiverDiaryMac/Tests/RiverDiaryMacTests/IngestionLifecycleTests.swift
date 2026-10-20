import XCTest
@testable import RiverDiaryMac

/// T04：退出登录时停止采集服务，排定必须真的被取消。
@MainActor
final class IngestionLifecycleTests: XCTestCase {
    func testStopCancelsTheScheduledCapture() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "ingestion.enabled")
        defaults.set(true, forKey: "ingestion.enabled")
        defer {
            if let previous {
                defaults.set(previous, forKey: "ingestion.enabled")
            } else {
                defaults.removeObject(forKey: "ingestion.enabled")
            }
        }

        let store = DataIngestionStore()
        store.start()
        XCTAssertTrue(store.isScheduled, "start() must schedule the daily capture")

        // 退出登录时的调用路径。
        store.stop()
        XCTAssertFalse(store.isScheduled, "stop() must cancel the timer")
        XCTAssertEqual(store.lastStatus, "定时采集已停止")
    }
}
