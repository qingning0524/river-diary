import XCTest
@testable import RiverDiaryMac

final class HealthMoodDraftTests: XCTestCase {
    func testNewMoodCannotSaveDefaultMidpointBeforeUserConfirmsIt() {
        var draft = MoodScoreDraft(persistedValue: nil)

        XCTAssertFalse(draft.showsEditor)
        draft.beginRecording()

        XCTAssertEqual(draft.sliderValue, 50)
        XCTAssertTrue(draft.isAwaitingSelection)
        XCTAssertFalse(draft.canSave)
        XCTAssertNil(draft.persistedValue)
    }

    func testUserCanExplicitlyConfirmDefaultMidpointAsMoodScore() {
        var draft = MoodScoreDraft(persistedValue: nil)
        draft.beginRecording()
        draft.confirmCurrentValue()

        XCTAssertEqual(draft.value, 50)
        XCTAssertFalse(draft.isAwaitingSelection)
        XCTAssertTrue(draft.canSave)

        draft.markSaved()
        XCTAssertEqual(draft.persistedValue, 50)
        XCTAssertFalse(draft.canSave)
    }

    func testMovingSliderEnablesSaveAndCancelRestoresUnknown() {
        var draft = MoodScoreDraft(persistedValue: nil)
        draft.beginRecording()
        draft.select(0)

        XCTAssertEqual(draft.value, 0)
        XCTAssertTrue(draft.canSave)

        draft.cancel()
        XCTAssertNil(draft.value)
        XCTAssertNil(draft.persistedValue)
        XCTAssertFalse(draft.showsEditor)
        XCTAssertFalse(draft.canSave)
    }

    func testExistingScoreCanOnlySaveWhenChangedAndCancelRestoresIt() {
        var draft = MoodScoreDraft(persistedValue: 72)
        XCTAssertTrue(draft.showsEditor)
        XCTAssertFalse(draft.canSave)

        draft.select(72)
        XCTAssertFalse(draft.canSave)
        draft.select(80)
        XCTAssertTrue(draft.canSave)

        draft.cancel()
        XCTAssertEqual(draft.value, 72)
        XCTAssertEqual(draft.persistedValue, 72)
        XCTAssertFalse(draft.canSave)
    }
}
