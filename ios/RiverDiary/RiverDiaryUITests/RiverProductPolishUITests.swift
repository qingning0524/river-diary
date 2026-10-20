import XCTest

final class RiverProductPolishUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--riverdiary-qa-visual-session", "--riverdiary-qa-modern-fixtures", "--riverdiary-qa-product-fixtures", "--riverdiary-qa-reset-local-state"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["river.tab.timeline"].waitForExistence(timeout: 20))
        return app
    }
    private func capture(_ app: XCUIApplication, _ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
    }
    func testRiverComposerRemainsVisibleAboveKeyboard() {
        let app = launch()
        app.buttons["river.tab.river"].tap()
        let input = app.textFields["river.chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertTrue(input.isHittable)
        capture(app, "River before keyboard")
        input.tap(); input.typeText("What happened today? Please use the saved records.")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture(app, "River with keyboard")
        XCTAssertTrue(input.isHittable)
        XCTAssertLessThanOrEqual(input.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        XCTAssertFalse(app.buttons["river.tab.river"].exists, "Keyboard editing should not lose space to the application navigation bar")
        XCTAssertTrue(app.buttons["river.chat.send"].isHittable)
        app.buttons["river.chat.send"].tap()
        XCTAssertTrue(app.buttons["river.tab.river"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["What happened today? Please use the saved records."].exists)
        capture(app, "River sent question")
    }

    func testLargeTextKeyboardCanSendAndRestoreNavigation() {
        let app = launch(large: true)
        app.buttons["river.tab.river"].tap()
        let input = app.textFields["river.chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 8)); input.tap(); input.typeText("My records today")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["river.chat.send"].isHittable)
        XCTAssertLessThanOrEqual(input.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        capture(app, "River large text keyboard")
        app.buttons["river.chat.dismissKeyboard"].tap()
        XCTAssertTrue(app.buttons["river.tab.timeline"].waitForExistence(timeout: 5))
    }

}
