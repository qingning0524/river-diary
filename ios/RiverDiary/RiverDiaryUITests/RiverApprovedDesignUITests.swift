import XCTest

/// Acceptance for the user-approved October 15 five-page iOS design.
/// The earlier four-page UI tests describe an obsolete navigation contract.
final class RiverApprovedDesignUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(fixtures: Bool = true, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--riverdiary-qa-visual-session", "--riverdiary-qa-reset-local-state"]
        if fixtures { app.launchArguments += ["--riverdiary-qa-modern-fixtures", "--riverdiary-qa-product-fixtures"] }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["river.global.date"].waitForExistence(timeout: 20))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<14 {
            if element.exists && element.isHittable { return }
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
    }

    func testApprovedFivePagesAndScrollingHeading() {
        let app = launch()
        let pages = [("timeline", "今天"), ("footprints", "足迹"), ("confirmations", "待确认"), ("river", "River"), ("me", "我的")]
        for (id, name) in pages {
            let tab = app.buttons["river.tab.\(id)"]
            XCTAssertTrue(tab.exists)
            XCTAssertTrue(tab.label.hasPrefix(name))
            tab.tap()
            XCTAssertTrue(app.buttons["river.global.date"].isHittable)
            capture(app, "Approved five-page design - \(name)")
        }
        app.buttons["river.tab.timeline"].tap()
        XCTAssertTrue(app.staticTexts["今日自动小结"].exists)
        let heading = app.descendants(matching: .any).matching(identifier: "river.page.heading.timeline").firstMatch
        XCTAssertTrue(heading.exists)
        let initialHeadingY = heading.frame.minY
        let initialDateY = app.buttons["river.global.date"].frame.minY
        app.swipeUp()
        XCTAssertEqual(app.buttons["river.global.date"].frame.minY, initialDateY, accuracy: 2)
        XCTAssertTrue(!heading.isHittable || heading.frame.minY < initialHeadingY - 20)
        capture(app, "Scrolling page title and persistent shared date")
    }

    func testOptionalSupplementRestoresDraftAndSearchesSavedText() {
        let app = launch(fixtures: false)
        let supplement = app.buttons["river.today.supplement"]
        reveal(supplement, in: app)
        supplement.tap()
        let editor = app.textFields["river.journal.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.tap(); editor.typeText("Approved five page draft continuity")
        app.buttons["river.journal.close"].tap()
        app.terminate()
        app.launchArguments = ["--riverdiary-qa-visual-session"]
        app.launch()
        XCTAssertTrue(app.buttons["river.global.date"].waitForExistence(timeout: 20))
        reveal(supplement, in: app)
        supplement.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        XCTAssertEqual(editor.value as? String, "Approved five page draft continuity")
        app.buttons["river.journal.save"].tap()
        XCTAssertTrue(app.buttons["river.tab.me"].waitForExistence(timeout: 8))
        app.buttons["river.tab.me"].tap()
        let search = app.textFields["river.memory.search"]
        reveal(search, in: app)
        search.tap(); search.typeText("continuity")
        let saved = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Approved five page draft continuity")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
        capture(app, "Saved supplement in approved My archive")
    }

    // These regressions follow the approved five-page shell. Legacy page arrows,
    // manual-first hierarchy and hidden map/timeline toggles are no longer contracts.
    func testFootprintsKeepMapTimelineFilteringAndOriginalEvidence() {
        let app = launch()
        app.buttons["river.tab.footprints"].tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 10))
        let jump = app.buttons["river.footprints.jumpToTimeline"]
        reveal(jump, in: app); jump.tap()
        let fact = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "river.footprints.timeline.record.")).firstMatch
        reveal(fact, in: app); fact.tap()
        XCTAssertTrue(app.navigationBars["活动详情"].waitForExistence(timeout: 8))
        reveal(app.staticTexts["来源与状态"], in: app)
        capture(app, "Approved footprint with original evidence")
        app.navigationBars["活动详情"].buttons.firstMatch.tap()
        let filters = app.buttons["搜索与筛选足迹"]
        reveal(filters, in: app, towardTop: true); filters.tap()
        let query = app.textFields["输入关键词"]
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeText("no-match-approved-987")
        app.navigationBars["搜索与筛选"].buttons["完成"].tap()
        reveal(app.staticTexts["没有找到相关片段"], in: app)
    }

    func testInlineFactCorrectionClosesOnlyItsPendingCard() {
        let app = launch()
        app.buttons["river.tab.confirmations"].tap()
        let facts = app.segmentedControls["river.confirmations.category"].buttons["事实"]
        XCTAssertTrue(facts.waitForExistence(timeout: 5)); facts.tap()
        let customize = app.buttons["补充或纠正这条理解"]
        reveal(customize, in: app); customize.tap()
        let field = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "river.confirmation.custom.")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let id = String(field.identifier.dropFirst("river.confirmation.custom.".count))
        field.tap(); field.typeText("是在整理工作笔记，不是在写日记。")
        if app.buttons["完成"].exists { app.buttons["完成"].tap() }
        let submit = app.buttons["river.confirmation.submit.\(id)"]
        reveal(submit, in: app); XCTAssertTrue(submit.isEnabled); submit.tap()
        let card = app.descendants(matching: .any).matching(identifier: "river.confirmation.\(id)").firstMatch
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 8), .completed)
        let places = app.segmentedControls["river.confirmations.category"].buttons["地点"]
        places.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "river.confirmation.submit.")).firstMatch.exists,
                      "Correcting one fact must not remove another place question.")
    }

    private func openAppearance(_ app: XCUIApplication) {
        app.buttons["river.tab.me"].tap()
        let settings = app.buttons["river.memory.settings"]
        reveal(settings, in: app, towardTop: true); settings.tap()
        let appearance = app.buttons["river.theme.open"]
        reveal(appearance, in: app); appearance.tap()
        XCTAssertTrue(app.navigationBars["阅读与外观"].waitForExistence(timeout: 5))
    }

    func testThreeAppearancesKeepFivePagesAndPersistSelection() {
        let app = launch()
        for id in ["clear_life", "contemporary_journal", "night_dashboard"] {
            openAppearance(app)
            let choice = app.buttons["river.theme.\(id)"]
            reveal(choice, in: app); choice.tap(); XCTAssertTrue(choice.isSelected)
            app.navigationBars["阅读与外观"].buttons.firstMatch.tap()
            let close = app.buttons["river.settings.close"]
            reveal(close, in: app, towardTop: true); close.tap()
            for tab in ["timeline", "footprints", "confirmations", "river", "me"] {
                app.buttons["river.tab.\(tab)"].tap()
                XCTAssertTrue(app.buttons["river.global.date"].isHittable)
            }
            app.buttons["river.tab.timeline"].tap()
            XCTAssertTrue(app.staticTexts["今日自动小结"].exists)
        }
        app.terminate(); app.launchArguments = ["--riverdiary-qa-visual-session"]; app.launch()
        XCTAssertTrue(app.buttons["river.global.date"].waitForExistence(timeout: 20))
        openAppearance(app)
        XCTAssertTrue(app.buttons["river.theme.night_dashboard"].isSelected)
    }

    func testLargestTextSupplementSavesAndReopensWithoutInventingARating() {
        let app = launch(fixtures: false, large: true)
        let supplement = app.buttons["river.today.supplement"]
        reveal(supplement, in: app); supplement.tap()
        let editor = app.textFields["river.journal.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8)); editor.tap(); editor.typeText("Approved large text saved note")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(editor.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        XCTAssertEqual(app.switches["river.journal.rating.enabled"].value as? String, "0")
        XCTAssertTrue(app.buttons["river.journal.save"].isHittable); app.buttons["river.journal.save"].tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 8), .completed)
        reveal(supplement, in: app); supplement.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Approved large text saved note")
        app.buttons["river.journal.close"].tap()
        capture(app, "Approved large text optional supplement")
    }

    func testFavoriteSurvivesRelaunchAndArchiveCanContinueWriting() {
        let app = launch()
        app.buttons["river.tab.me"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "river.memory.journal.")).firstMatch
        reveal(entry, in: app); entry.press(forDuration: 1)
        app.buttons["收藏日记"].tap()
        app.terminate(); app.launchArguments = ["--riverdiary-qa-visual-session"]; app.launch()
        XCTAssertTrue(app.buttons["river.global.date"].waitForExistence(timeout: 20))
        app.buttons["river.tab.me"].tap(); reveal(entry, in: app); entry.press(forDuration: 1)
        XCTAssertTrue(app.buttons["取消收藏"].waitForExistence(timeout: 5)); app.buttons["取消收藏"].tap()
        let journals = app.buttons["river.memory.journals"]
        reveal(journals, in: app); journals.tap()
        let archived = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "river.journal.archive.")).firstMatch
        reveal(archived, in: app); archived.tap()
        let edit = app.buttons["river.journal.read.edit"]
        reveal(edit, in: app); edit.tap()
        let editor = app.textFields["river.journal.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        XCTAssertTrue((editor.value as? String)?.contains("没有急着开始工作") == true)
        app.buttons["river.journal.close"].tap()
    }

}
