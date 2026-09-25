import XCTest
@testable import RiverDiaryMac

final class TimelineAnnotationTests: XCTestCase {
    private let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    private func session(_ minute: Double, duration: Double = 10) -> ActivitySession {
        ActivitySession(appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "原始窗口", category: "工作",
                        start: day.addingTimeInterval(minute * 60), end: day.addingTimeInterval((minute + duration) * 60))
    }

    func testEditedSegmentIsNotSwallowedByAutomaticGrouping() throws {
        let first = session(600)
        let second = session(610)
        let annotation = TimelineAnnotation(title: "把一件事做好", note: "终于想清楚了", isFavorite: true)
        let key = TimelineAnnotation.key(for: second)
        let timeline = ActivityTimelineEngine.build(for: day, sessions: [first, second], annotations: [key: annotation])
        XCTAssertEqual(timeline.items.filter { $0.kind == .activity }.count, 2)
        let edited = try XCTUnwrap(timeline.items.last)
        XCTAssertEqual(edited.narrativeTitle, annotation.title)
        XCTAssertEqual(edited.sessions.first?.windowTitle, "原始窗口")
        XCTAssertTrue(edited.isFavorite)
        XCTAssertTrue(edited.matches(query: "想清楚", category: "工作"))
        let raw = ActivityTimelineEngine.build(for: day, sessions: [first, second], grouped: false, annotations: [key: annotation])
        XCTAssertEqual(raw.items.last?.annotation, annotation)
        let markdown = ActivityTimelineExport.markdown(timeline)
        XCTAssertTrue(markdown.contains(annotation.title))
        XCTAssertTrue(markdown.contains(annotation.note))
        XCTAssertTrue(markdown.contains("原始窗口"))
        XCTAssertTrue(markdown.contains("★ 已收藏"))
    }

    func testAnnotationKeySurvivesUUIDChangeAndSecondPrecisionPersistence() {
        var live = session(600.012)
        let key = TimelineAnnotation.key(for: live)
        live.id = UUID()
        live.start = Date(timeIntervalSince1970: floor(live.start.timeIntervalSince1970))
        live.end = live.end.addingTimeInterval(300)
        XCTAssertEqual(TimelineAnnotation.key(for: live), key)
    }

    func testClearingAllPersonalFieldsRestoresAutomaticTitle() {
        let source = session(600)
        let key = TimelineAnnotation.key(for: source)
        let values = [key: TimelineAnnotation(title: "我的标题", note: "备注", isFavorite: true)]
        let cleared = TimelineAnnotation.updating(values, key: key, with: TimelineAnnotation(title: " \n", note: " "))
        XCTAssertTrue(cleared.isEmpty)
        let timeline = ActivityTimelineEngine.build(for: day, sessions: [source], annotations: cleared)
        XCTAssertEqual(timeline.items.first?.narrativeTitle, "原始窗口")
        XCTAssertEqual(values[key]?.title, "我的标题", "Preparing a save must not mutate the existing state")
    }

    func testFavoriteOnlyAnnotationIsRetainedAndFieldsAreTrimmed() {
        let values = TimelineAnnotation.updating([:], key: "test", with: TimelineAnnotation(title: " \n", note: "  一句话  ", isFavorite: true))
        XCTAssertEqual(values["test"]?.title, "")
        XCTAssertEqual(values["test"]?.note, "一句话")
        XCTAssertEqual(values["test"]?.isFavorite, true)
    }

    func testManualPlaceAndActivityLabelsAreTrimmedAndRetained() {
        let annotation = TimelineAnnotation(
            placeName: "  图书馆  ",
            activityLabel: " 学习 ",
            isReviewed: true
        )
        let values = TimelineAnnotation.updating([:], key: "test", with: annotation)

        XCTAssertEqual(values["test"]?.placeName, "图书馆")
        XCTAssertEqual(values["test"]?.activityLabel, "学习")
        XCTAssertTrue(values["test"]?.isReviewed == true)
    }

    func testLegacyAnnotationDecodesWithoutManualCorrectionFields() throws {
        let decoder = JSONDecoder()
        let legacy = Data(#"{"title":"旧标题","note":"旧备注","isFavorite":true,"isReviewed":false}"#.utf8)
        let annotation = try decoder.decode(TimelineAnnotation.self, from: legacy)

        XCTAssertEqual(annotation.title, "旧标题")
        XCTAssertEqual(annotation.note, "旧备注")
        XCTAssertEqual(annotation.placeName, "")
        XCTAssertEqual(annotation.activityLabel, "")
        XCTAssertTrue(annotation.isFavorite)
    }

    func testReviewedAnnotationIsRetainedWithoutTitleOrNote() {
        let reviewed = TimelineAnnotation(isReviewed: true, reviewedAt: day)
        let values = TimelineAnnotation.updating([:], key: "test", with: reviewed)

        XCTAssertEqual(values["test"]?.isReviewed, true)
        XCTAssertEqual(values["test"]?.reviewedAt, day)
        XCTAssertFalse(values["test"]?.isEmpty ?? true)
    }

    func testStateAndBackupRoundTripAndLegacyCompatibility() throws {
        let annotation = TimelineAnnotation(title: "完成一段写作", note: "很安静", isFavorite: true, updatedAt: day)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = UserState(timelineAnnotations: ["key": annotation])
        XCTAssertEqual(try decoder.decode(UserState.self, from: encoder.encode(state)).timelineAnnotations?["key"], annotation)
        let backup = LocalBackupPayload(exportedAt: day, overrides: [:], quickCaptures: [:], dismissedDrafts: [:], careAcknowledgments: [:], timelineAnnotations: ["key": annotation])
        XCTAssertEqual(try decoder.decode(LocalBackupPayload.self, from: encoder.encode(backup)).timelineAnnotations?["key"], annotation)
        XCTAssertNil(try decoder.decode(UserState.self, from: Data(#"{"version":3,"entries":{}}"#.utf8)).timelineAnnotations)
        let legacyBackup = LocalBackupPayload(exportedAt: day, overrides: [:], quickCaptures: [:], dismissedDrafts: [:], careAcknowledgments: [:])
        XCTAssertNil(try decoder.decode(LocalBackupPayload.self, from: encoder.encode(legacyBackup)).timelineAnnotations)
    }

    func testActiveSessionAppearsOnBothSidesOfMidnightWithoutInflatingEitherDay() throws {
        let active = session(-30, duration: 0)
        let now = day.addingTimeInterval(20 * 60)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        let today = ActivitySessionSnapshot.day(day, sessions: [], active: active, now: now)
        let prior = ActivitySessionSnapshot.day(yesterday, sessions: [], active: active, now: now)
        XCTAssertEqual(today.first?.duration, 20 * 60)
        XCTAssertEqual(prior.first?.duration, 30 * 60)
        XCTAssertEqual(today.first?.start, day)
        XCTAssertEqual(prior.first?.end, day)
    }

    func testStoredCrossMidnightSessionIsClippedLikeTheLiveSnapshot() {
        let stored = session(-30, duration: 50)
        let today = ActivitySessionSnapshot.day(day, sessions: [stored], active: nil)
        XCTAssertEqual(today.first?.duration, 20 * 60)
        XCTAssertTrue(ActivitySessionSnapshot.day(day, sessions: [session(-120)], active: nil).isEmpty)
        var lock = stored
        lock.appName = "loginwindow"
        XCTAssertTrue(ActivitySessionSnapshot.day(day, sessions: [lock], active: nil).isEmpty)
    }
}
