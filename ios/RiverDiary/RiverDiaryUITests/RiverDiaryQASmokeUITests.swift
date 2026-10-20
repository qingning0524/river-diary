import XCTest

final class RiverDiaryQASmokeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func attachScreen(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchIsolatedQAApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--riverdiary-qa-reset-local-state", "--riverdiary-qa-visual-session"]
        app.launch()
        return app
    }


    func testQASyncKeyImportThroughSettingsUI() throws {
        guard let syncCode = Bundle(for: Self.self).infoDictionary?["RIVER_DIARY_QA_SYNC_KEY"] as? String,
              syncCode.hasPrefix("river-sync-v1:") else {
            throw XCTSkip("Build with the isolated QA_SYNC_KEY test setting to exercise key import.")
        }

        let app = launchIsolatedQAApp()
        XCTAssertTrue(app.buttons["river.tab.me"].waitForExistence(timeout: 10))
        app.buttons["river.tab.me"].tap()
        app.buttons["river.memory.settings"].tap()
        XCTAssertTrue(app.staticTexts["river.settings.title"].waitForExistence(timeout: 5))
        let syncLink = app.buttons["river.settings.sync"]
        for _ in 0..<12 where !syncLink.isHittable { app.swipeUp() }
        XCTAssertTrue(syncLink.isHittable)
        syncLink.tap()
        XCTAssertTrue(app.navigationBars["设备与同步"].waitForExistence(timeout: 5))

        let syncKeyField = app.textFields["粘贴另一设备的同步密钥"]
        for _ in 0..<12 where !syncKeyField.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(syncKeyField.waitForExistence(timeout: 5))
        syncKeyField.tap()
        syncKeyField.typeText(syncCode)
        let dismissKeyboardButton = app.buttons["settings.keyboardDone"]
        XCTAssertTrue(dismissKeyboardButton.waitForExistence(timeout: 5))
        dismissKeyboardButton.tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)

        let importButton = app.buttons["导入同步密钥"]
        XCTAssertTrue(importButton.isEnabled)
        importButton.tap()

        let syncStatus = app.descendants(matching: .any)["river.syncStatus"]
        for _ in 0..<12 where !syncStatus.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(syncStatus.isHittable)
        let statusText = syncStatus.label
        XCTAssertTrue(
            statusText.contains("同步密钥已导入") || statusText.contains("请先选择共享文件夹"),
            "Unexpected QA sync status: \(statusText)"
        )

        let revealKeyButton = app.buttons["显示或创建同步密钥"]
        for _ in 0..<10 where !revealKeyButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(revealKeyButton.isHittable)
        revealKeyButton.tap()
        let displayedLabels = app.staticTexts.allElementsBoundByIndex.map(\.label)
        let importedExpectedKey = displayedLabels.contains(syncCode)
        let hideKeyButton = app.buttons["隐藏密钥"]
        if hideKeyButton.exists { hideKeyButton.tap() }
        XCTAssertTrue(importedExpectedKey, "The QA key did not persist in the app Keychain.")
    }
}
