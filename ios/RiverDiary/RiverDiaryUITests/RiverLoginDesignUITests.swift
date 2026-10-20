import XCTest

final class RiverLoginDesignUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(code: Bool = false, large: Bool = false, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [code ? "--riverdiary-qa-login-code-preview" : "--riverdiary-qa-login-preview"]
        if reset { app.launchArguments += ["--riverdiary-qa-reset-local-state"] }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); XCTAssertTrue(app.buttons["account.appearance"].waitForExistence(timeout: 15)); return app
    }
    private func capture(_ app: XCUIApplication, _ label: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "Login · " + label; a.lifetime = .keepAlways; add(a)
    }
    private func choose(_ id: String, app: XCUIApplication) {
        app.buttons["account.appearance"].tap()
        let option = app.buttons["account.style.\(id)"]
        XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
    }
    func testEmailEntryAppearanceAndPrivacySheetWithoutSendingMail() {
        let app = launch()
        XCTAssertFalse(app.buttons["account.sendCode"].isEnabled)
        XCTAssertEqual(app.buttons["account.acceptTerms"].value as? String, "未同意")
        capture(app, "clear_life-empty")
        let email = app.textFields["account.email"]
        email.tap(); email.typeText("hello@example.com")
        XCTAssertTrue(app.buttons["account.sendCode"].isEnabled)
        capture(app, "keyboard-email")
        app.buttons["account.keyboardDone"].tap()
        for id in ["clear_life", "contemporary_journal", "night_dashboard"] {
            choose(id, app: app); capture(app, id + "-email")
            XCTAssertTrue(app.textFields["account.email"].isHittable)
            XCTAssertTrue(app.buttons["account.sendCode"].isHittable)
            XCTAssertTrue(app.buttons["account.sendCode"].isEnabled)
        }
        app.buttons["account.terms.open"].tap()
        XCTAssertTrue(app.navigationBars["账号服务与隐私说明"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["账号服务"].exists); capture(app, "privacy")
        app.buttons["关闭"].tap(); XCTAssertEqual(app.buttons["account.acceptTerms"].value as? String, "未同意")
        // Never submit an email request, accept terms, or perform a sign-in in visual QA.
    }
    func testCodeEntryAndRecipientChangeWithoutAuthentication() {
        let app = launch(code: true)
        for id in ["clear_life", "contemporary_journal", "night_dashboard"] { choose(id, app: app); capture(app, id + "-code") }
        let code = app.textFields["account.code"]
        code.tap(); code.typeText("1234567890")
        XCTAssertEqual(code.value as? String, "12345678")
        XCTAssertFalse(app.buttons["account.verifyCode"].isEnabled)
        app.buttons["account.keyboardDone"].tap(); capture(app, "code-filled")
        app.buttons["account.changeEmail"].tap()
        XCTAssertTrue(app.textFields["account.email"].waitForExistence(timeout: 5)); XCTAssertFalse(app.textFields["account.code"].exists)
    }
    func testPasswordLoginAndRecoveryAcrossThemesWithoutNetwork() {
        let app = launch()
        app.buttons["account.method.password"].tap()
        XCTAssertTrue(app.secureTextFields["account.password"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["account.password.login"].isEnabled)
        let email = app.textFields["account.email"]
        email.tap(); email.typeText("hello@example.com")
        app.buttons["account.keyboardDone"].tap()
        for id in ["clear_life", "contemporary_journal", "night_dashboard"] {
            if id != "clear_life" { choose(id, app: app) }
            capture(app, id + "-password")
            XCTAssertTrue(app.buttons["account.password.forgot"].isHittable)
            app.buttons["account.password.forgot"].tap()
            XCTAssertTrue(app.textFields["account.password.reset.email"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields["account.password.reset.email"].value as? String, "hello@example.com")
            XCTAssertTrue(app.buttons["account.password.reset.submit"].isEnabled)
            capture(app, id + "-recovery")
            app.buttons["关闭"].tap()
        }
        let password = app.secureTextFields["account.password"]
        password.tap(); password.typeText("a quiet river phrase 2026")
        app.buttons["account.keyboardDone"].tap()
        XCTAssertFalse(app.buttons["account.password.login"].isEnabled)
        app.buttons["account.password.visibility"].tap()
        XCTAssertEqual(app.textFields["account.password"].value as? String, "a quiet river phrase 2026")
        // Do not accept consent or submit credentials/mail requests in UI verification.
    }
    func testRecoveryPasswordFieldsAndValidationWithoutMail() {
        let app = XCUIApplication()
        app.launchArguments = ["--riverdiary-qa-login-preview", "--riverdiary-qa-password-reset-preview", "--riverdiary-qa-reset-local-state"]
        app.launch()
        XCTAssertTrue(app.buttons["account.method.password"].waitForExistence(timeout: 15))
        app.buttons["account.method.password"].tap()
        app.buttons["account.password.forgot"].tap()
        XCTAssertTrue(app.secureTextFields["account.password.reset.new"].waitForExistence(timeout: 5))
        capture(app, "clear_life-reset-form")
        app.textFields["account.password.reset.code"].tap(); app.textFields["account.password.reset.code"].typeText("123456789")
        XCTAssertEqual(app.textFields["account.password.reset.code"].value as? String, "12345678")
        let password = app.secureTextFields["account.password.reset.new"]
        password.tap(); password.typeText("short")
        XCTAssertTrue(app.staticTexts["account.password.reset.policy"].exists)
        let repeated = app.secureTextFields["account.password.reset.confirm"]
        repeated.tap(); repeated.typeText("different")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["account.password.reset.mismatch"].exists)
        XCTAssertFalse(app.buttons["account.password.reset.submit"].isEnabled)
        capture(app, "reset-validation")
    }
    func testLargeTextLoginControlsAndPolicyRemainReachable() {
        let app = launch(large: true)
        let email = app.textFields["account.email"]
        for _ in 0..<6 where !email.isHittable { app.swipeUp() }
        XCTAssertTrue(email.isHittable); email.tap(); email.typeText("hello@example.com")
        app.buttons["account.keyboardDone"].tap()
        for _ in 0..<6 where !app.buttons["account.sendCode"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["account.sendCode"].isHittable); capture(app, "large-email")
        app.buttons["account.terms.open"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5)); capture(app, "large-policy")
    }
}
