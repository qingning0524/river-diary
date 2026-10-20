import XCTest
@testable import RiverDiaryMac

final class FootprintMomentsTests: XCTestCase {
    private var day: Date { DiaryEntry.dateFormatter.date(from: "2026-10-15")! }
    private func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }
    private func session(_ start: Double, _ end: Double, category: String = "工作", title: String? = nil, app: String = "Xcode") -> ActivitySession {
        ActivitySession(appName: app, bundleID: "test.\(app)", windowTitle: title, category: category,
                        start: at(start), end: at(end))
    }
    private func timeline(_ sessions: [ActivitySession] = [], captures: [QuickCapture] = [],
                          markers: [ActivityTimelinePlaceMarker] = []) -> ActivityTimeline {
        ActivityTimelineEngine.build(for: day, sessions: sessions, captures: captures, placeMarkers: markers)
    }

    func testCardsUseRecordedMomentsInDescendingOrderAndExcludeGaps() {
        let model = timeline([session(540, 600), session(780, 840, category: "娱乐", app: "Safari")],
                             captures: [QuickCapture(text: "一段真实的手记", createdAt: at(720))])
        let cards = FootprintMoments.items(in: model, scope: .all, query: "")
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards.map(\.start), [at(780), at(720), at(540)])
        XCTAssertFalse(cards.contains { $0.kind == .gap })
        XCTAssertEqual(cards.first?.duration, 3600)
        XCTAssertEqual(cards.first { $0.kind == .capture }?.duration, 0, "手记没有活动时长，不能编造分钟数")
    }

    func testMovementRequiresExplicitCategoryOrUserContextNotWindowTitle() {
        let source = session(540, 600, title: "跑步与运动设计文档")
        var item = timeline([source]).items.first { $0.kind == .activity }!
        XCTAssertEqual(FootprintMoments.scope(of: item), .focus)
        item.annotation = TimelineAnnotation(activityLabel: "跑步")
        XCTAssertEqual(FootprintMoments.scope(of: item), .movement)
        let note = QuickCapture(text: "今天的记录", createdAt: at(700), tag: "运动")
        let noteItem = timeline(captures: [note]).items.first!
        XCTAssertEqual(FootprintMoments.scope(of: noteItem), .movement)
    }

    func testScopeAndSearchExpandFragmentMembersRatherThanHidingMatches() throws {
        let sessions = (0..<10).map { index in
            session(540 + Double(index), 540.5 + Double(index), category: index.isMultiple(of: 2) ? "工作" : "娱乐",
                    title: "成员-\(index)", app: "App\(index)")
        }
        let model = timeline(sessions)
        XCTAssertTrue(model.foldedItems.contains(where: \.isFragmentRun))
        let filtered = FootprintMoments.items(in: model, scope: .focus, query: "成员-2")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertFalse(try XCTUnwrap(filtered.first).isFragmentRun)
        XCTAssertEqual(filtered.first?.sessions.first?.windowTitle, "成员-2")
        XCTAssertTrue(FootprintMoments.items(in: model, scope: .life, query: "成员-2").isEmpty)
    }

    func testPlaceOverviewUsesOnlyPlaceEventsAndExplicitAnnotations() {
        let marker = ActivityTimelinePlaceMarker(id: UUID(), time: at(800), title: "到达图书馆", detail: "位置来源", originDeviceID: "test-phone")
        var model = timeline([session(540, 600, title: "街角咖啡 · 浏览网页")], markers: [marker])
        XCTAssertEqual(FootprintMoments.places(in: model).map(\.name), ["到达图书馆"])
        let index = model.items.firstIndex { $0.kind == .activity }!
        model.items[index].annotation = TimelineAnnotation(placeName: "由我标注的书房")
        XCTAssertEqual(FootprintMoments.places(in: model).map(\.name), ["由我标注的书房", "到达图书馆"])
    }

    func testSharedPendingAndFavoritesAreCombinedWithOtherFilters() throws {
        var model = timeline([session(540, 600, title: "设计记录"), session(780, 840, category: "娱乐", title: "阅读", app: "Safari")])
        let index = model.items.firstIndex { $0.kind == .activity }!
        model.items[index].annotation = TimelineAnnotation(isFavorite: true, isReviewed: true)
        model.foldedItems = model.items
        let target = model.items[index]
        let selected = FootprintMoments.items(in: model, scope: .focus, query: "设计", favoritesOnly: true,
                                             pendingOnly: true, pendingTargets: [try XCTUnwrap(target.annotationKey)])
        XCTAssertEqual(selected.map(\.id), [target.id])
        XCTAssertTrue(FootprintMoments.items(in: model, scope: .life, query: "设计", favoritesOnly: true).isEmpty)
    }

    func testBackdatedWritingDoesNotAcquireAFictionalEventTime() {
        let model = timeline(captures: [QuickCapture(text: "今天补记昨天", createdAt: at(1500))])
        XCTAssertTrue(FootprintMoments.items(in: model, scope: .all, query: "").isEmpty)
        XCTAssertEqual(model.retrospectiveCaptures.count, 1)
    }
    func testMapUsesOnlyFiniteRecordedCoordinates() throws {
        let marker = ActivityTimelinePlaceMarker(id: UUID(), time: at(800), title: "坐标测试点", detail: "QA", originDeviceID: "test",
                                                latitude: 31.2, longitude: 121.4)
        let stop = try XCTUnwrap(FootprintMoments.places(in: timeline(markers: [marker])).first)
        XCTAssertEqual(try XCTUnwrap(stop.coordinate).latitude, 31.2)
        XCTAssertEqual(try XCTUnwrap(stop.coordinate).longitude, 121.4)
        var invalid = marker
        invalid.latitude = 91
        XCTAssertNil(FootprintMoments.places(in: timeline(markers: [invalid])).first?.coordinate)
        invalid.latitude = .nan
        XCTAssertNil(FootprintMoments.places(in: timeline(markers: [invalid])).first?.coordinate)
    }

    func testOlderPlaceMarkersDecodeWithoutInventedCoordinates() throws {
        let marker = ActivityTimelinePlaceMarker(id: UUID(), time: at(800), title: "旧地点记录", detail: "旧数据", originDeviceID: "test")
        let data = try JSONEncoder().encode(marker)
        let decoded = try JSONDecoder().decode(ActivityTimelinePlaceMarker.self, from: data)
        XCTAssertNil(decoded.latitude)
        XCTAssertNil(decoded.longitude)
        XCTAssertNil(FootprintMoments.places(in: timeline(markers: [decoded])).first?.coordinate)
    }

    func testOpenDetailResolvesSavedAnnotationInsteadOfItsSelectionSnapshot() throws {
        let item = try XCTUnwrap(timeline([session(540, 600, title: "原始窗口")]).items.first { $0.kind == .activity })
        let key = try XCTUnwrap(item.annotationKey)
        let resolved = item.refreshingAnnotation(from: [key: TimelineAnnotation(title: "新标题", placeName: "新地点", activityLabel: "运动", isFavorite: true)])
        XCTAssertEqual(resolved.title, "新标题")
        XCTAssertEqual(FootprintMoments.place(resolved), "新地点")
        XCTAssertEqual(FootprintMoments.scope(of: resolved), .movement)
        XCTAssertTrue(resolved.isFavorite)
        XCTAssertEqual(resolved.sessions, item.sessions)
    }

    func testClearingAnnotationRemovesStaleDetailContextButKeepsRawEvidence() throws {
        var item = try XCTUnwrap(timeline([session(540, 600, title: "原始窗口")]).items.first { $0.kind == .activity })
        item.annotation = TimelineAnnotation(title: "已被清除的标题", isFavorite: true)
        let resolved = item.refreshingAnnotation(from: [:])
        XCTAssertNil(resolved.annotation)
        XCTAssertFalse(resolved.isFavorite)
        XCTAssertEqual(resolved.evidenceLine, "原始窗口")
    }

}
