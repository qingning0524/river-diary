import XCTest
import SwiftUI
@testable import RiverDiary

@MainActor final class RiverThemeStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "river-style-test-" + UUID().uuidString
        let value = UserDefaults(suiteName: name)!
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }
    func testDefaultAndEveryRetiredThemeMigrateWithoutTouchingRecordsOrAISettings() throws {
        let oldIDs = ["river_journal", "city_roamer", "time_film", "light_everyday", "life_constellation", "day_garden", "life_weekly", "tidal_clock", "pocket_scrapbook", "pure_life"]
        for oldID in oldIDs {
            let d = defaults()
            d.set(try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "themeID": oldID, "appearance": "dark"]), forKey: RiverThemeStore.legacyPreferenceKey)
            d.set("keep my draft", forKey: "draft.test")
            d.set("https://my-provider.example/v1", forKey: "river.ai.endpoint")
            let store = RiverThemeStore(defaults: d)
            XCTAssertEqual(store.selectedThemeID, .clearLife)
            XCTAssertEqual(store.preferredColorScheme, .light)
            XCTAssertEqual(d.string(forKey: "draft.test"), "keep my draft")
            XCTAssertEqual(d.string(forKey: "river.ai.endpoint"), "https://my-provider.example/v1")
            XCTAssertNotNil(d.data(forKey: RiverThemeStore.legacyPreferenceKey))
        }
        XCTAssertEqual(RiverThemeStore(defaults: defaults()).selectedThemeID, .clearLife)
    }
    func testOptionalStylesSurviveRelaunchAndHaveTheirApprovedAppearance() {
        let d = defaults(), store = RiverThemeStore(defaults: d)
        XCTAssertEqual(RiverThemeID.allCases.count, 3)
        for id in RiverThemeID.allCases {
            _ = store.applyTheme(id)
            let restored = RiverThemeStore(defaults: d)
            XCTAssertEqual(restored.selectedThemeID, id)
            XCTAssertEqual(restored.context(for: .dark).colorScheme, id == .nightDashboard ? .dark : .light)
        }
    }
    func testUnknownOrCorruptedNewPreferencesFallBackToClearLife() throws {
        let d = defaults()
        d.set(Data("broken".utf8), forKey: RiverThemeStore.preferenceKey)
        XCTAssertEqual(RiverThemeStore(defaults: d).selectedThemeID, .clearLife)
        d.set(try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "themeID": "future-style"]), forKey: RiverThemeStore.preferenceKey)
        XCTAssertEqual(RiverThemeStore(defaults: d).selectedThemeID, .clearLife)
    }
}
