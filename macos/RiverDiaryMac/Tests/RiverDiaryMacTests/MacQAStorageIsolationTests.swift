import Foundation
import XCTest
@testable import RiverDiaryMac

final class MacQAStorageIsolationTests: XCTestCase {
    private let realHome = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    private let temporaryDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
    private let qaHome = URL(fileURLWithPath: "/tmp/RiverDiaryMacQAHome-test", isDirectory: true)

    func testProductionBundleDoesNotRequireQAEnvironment() {
        XCTAssertNil(MacQAStorageIsolation.startupError(
            bundleIdentifier: "studio.riverdiary.mac",
            environment: ["HOME": realHome.path],
            applicationSupportDirectory: realHome.appendingPathComponent("Library/Application Support"),
            temporaryDirectory: temporaryDirectory
        ))
    }

    func testQABundleFailsClosedWithoutIsolationEnvironment() {
        let error = MacQAStorageIsolation.startupError(
            bundleIdentifier: MacQAStorageIsolation.qaBundleIdentifier,
            environment: ["HOME": realHome.path],
            applicationSupportDirectory: realHome.appendingPathComponent("Library/Application Support"),
            temporaryDirectory: temporaryDirectory
        )
        XCTAssertEqual(error, "QA 版本必须通过隔离启动器设置独立用户目录。")
    }

    func testQABundleRejectsProductionUserHome() {
        let error = MacQAStorageIsolation.startupError(
            bundleIdentifier: MacQAStorageIsolation.qaBundleIdentifier,
            environment: [
                "HOME": realHome.path,
                "CFFIXED_USER_HOME": realHome.path,
                "RIVER_DIARY_MAC_QA_HOME": realHome.path,
            ],
            applicationSupportDirectory: realHome.appendingPathComponent("Library/Application Support"),
            temporaryDirectory: temporaryDirectory
        )
        XCTAssertEqual(error, "QA 版本拒绝使用正式用户目录。")
    }

    func testQABundleAcceptsAnExplicitIsolatedTemporaryHome() {
        let support = qaHome.appendingPathComponent("Library/Application Support", isDirectory: true)
        XCTAssertNil(MacQAStorageIsolation.startupError(
            bundleIdentifier: MacQAStorageIsolation.qaBundleIdentifier,
            environment: [
                "HOME": realHome.path,
                "CFFIXED_USER_HOME": qaHome.path,
                "RIVER_DIARY_MAC_QA_HOME": qaHome.path,
            ],
            applicationSupportDirectory: support,
            temporaryDirectory: temporaryDirectory
        ))
    }

    func testQABundleRejectsAProductionApplicationSupportPath() {
        let error = MacQAStorageIsolation.startupError(
            bundleIdentifier: MacQAStorageIsolation.qaBundleIdentifier,
            environment: [
                "HOME": realHome.path,
                "CFFIXED_USER_HOME": qaHome.path,
                "RIVER_DIARY_MAC_QA_HOME": qaHome.path,
            ],
            applicationSupportDirectory: realHome.appendingPathComponent("Library/Application Support"),
            temporaryDirectory: temporaryDirectory
        )
        XCTAssertEqual(error, "QA 应用支持目录与隔离用户目录不匹配。")
    }
}
