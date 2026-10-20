import Foundation

@main enum CheckDayReadingData {
    static func main() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 2))!
        func event(_ offset: Double, _ duration: Double) -> RiverRecordedInterval { RiverRecordedInterval(start: date.addingTimeInterval(offset), duration: duration) }
        func check(_ value: Bool, _ message: String) { precondition(value, message) }
        check(RiverDayReadingMath.recordedDuration([], on: date, calendar: cal) == nil, "Missing intervals must remain missing")
        check(RiverDayReadingMath.recordedDuration([event(3_600, 7_200), event(7_200, 7_200)], on: date, calendar: cal) == 10_800, "Overlapping devices must not double count time")
        check(RiverDayReadingMath.recordedDuration([event(3_600, 3_600), event(3_600, 3_600)], on: date, calendar: cal) == 3_600, "Duplicates must not double count")
        check(RiverDayReadingMath.recordedDuration([event(-3_600, 7_200), event(82_800, 7_200)], on: date, calendar: cal) == 7_200, "Cross-day sessions must be clipped")
        check(RiverDayReadingMath.recordedDuration([event(86_400, 3_600)], on: date, calendar: cal) == nil, "Next-day records must not enter this day")
        check(RiverDayReadingMath.recordedDuration([event(0, -.infinity), event(0, .nan)], on: date, calendar: cal) == nil, "Invalid durations must not become facts")
        check(RiverDayReadingMath.timeText(seconds: 25_920) == "7 小时 12 分", "Sleep decimals must become clear hours and minutes")
        check(RiverDayReadingMath.timeText(seconds: nil) == "未记录", "Missing must not become zero")
        check(RiverDayReadingMath.timeText(seconds: 0) == "0 分钟", "Real zero must remain zero")
        print("9 reading-data and duration checks passed")
    }
}
