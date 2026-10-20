import Foundation
import Testing
@testable import RiverDiaryCore

struct ObservedTimeDistributionTests {
    private func day() -> Date { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar.date(from: DateComponents(year: 2026, month: 10, day: 14))! }
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
    @Test func overlappingObservedSourcesAreNotDoubleCounted() {
        let start = day()
        let values = ObservedTimeDistribution.calculate([
            .init(id: "place", category: "地点停留", start: start, end: start.addingTimeInterval(7200), priority: 1),
            .init(id: "app", category: "应用活动", start: start.addingTimeInterval(1800), end: start.addingTimeInterval(3600), priority: 3)
        ], on: start, calendar: calendar)
        #expect(values.reduce(0) { $0 + $1.seconds } == 7200)
        #expect(values.first { $0.category == "应用活动" }?.percentage == 25)
        #expect(values.reduce(0) { $0 + $1.percentage } == 100)
    }
    @Test func onlyObservedIntervalsInsideTheSelectedDayContribute() {
        let start = day()
        let values = ObservedTimeDistribution.calculate([
            .init(id: "overnight", category: "应用活动", start: start.addingTimeInterval(-3600), end: start.addingTimeInterval(1800), priority: 3),
            .init(id: "future", category: "地点停留", start: start.addingTimeInterval(90000), end: start.addingTimeInterval(91000), priority: 1)
        ], on: start, calendar: calendar)
        #expect(values.count == 1)
        #expect(values[0].seconds == 1800)
    }
    @Test func noDurationDoesNotRequireTheUserToFillAnActivity() {
        #expect(ObservedTimeDistribution.calculate([], on: day(), calendar: calendar).isEmpty)
        #expect(ObservedTimeDistribution.calculate([.init(id: "point", category: "地点", start: day(), end: day(), priority: 1)], on: day(), calendar: calendar).isEmpty)
    }
    @Test func largestRemainderPercentagesStillTotalOneHundred() {
        let start = day()
        let intervals = (0..<3).map { index in ObservedTimeInterval(id: "\(index)", category: "来源\(index)", start: start.addingTimeInterval(Double(index * 60)), end: start.addingTimeInterval(Double((index + 1) * 60)), priority: 1) }
        let values = ObservedTimeDistribution.calculate(intervals, on: start, calendar: calendar)
        #expect(values.map(\.percentage).sorted() == [33, 33, 34])
    }
}

extension ObservedTimeDistributionTests {
    @Test func observedAppActivityBuildsWithoutManualTextOrUserConfirmation() throws {
        let device = RiverDeviceID(rawValue: "automation-test-phone")
        let payload = try JSONEncoder().encode(RiverEventPayload(appName: "学习工具", bundleID: "example.study"))
        let start = Date(timeIntervalSince1970: 1000)
        let events = [RiverEvent(originDeviceID: device, originSequence: 1, observedAt: start, source: "shortcuts", kind: "app.opened", payload: payload),
                      RiverEvent(originDeviceID: device, originSequence: 2, observedAt: start.addingTimeInterval(1200), source: "shortcuts", kind: "app.closed", payload: payload)]
        let sessions = SessionBuilder.build(events)
        #expect(sessions.count == 1)
        #expect(sessions[0].quality == .observed)
        #expect(sessions[0].duration == 1200)
        // Evidence IDs are a set persisted in canonical UUID order for
        // cross-device determinism, not in observation order.
        #expect(Set(sessions[0].evidenceEventIDs) == Set(events.map(\.id)))
        #expect(events.allSatisfy { $0.source != "manual" })
    }
}
