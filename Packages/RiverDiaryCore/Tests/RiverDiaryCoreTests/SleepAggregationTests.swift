import Foundation
import Testing
@testable import RiverDiaryCore

struct SleepAggregationTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func unsegmentedSleepStillCountsAsSleep() {
        // 只给“睡着了”、没有分期的来源不能算 0 小时。
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(20, 23), end: date(21, 7), stage: .unspecified)
        ], calendar: calendar)

        #expect(nights.count == 1)
        #expect(nights[0].day == date(21, 0))
        #expect(nights[0].asleepSeconds == 8 * 3600)
        #expect(nights[0].coverage(for: .unspecified) == 8 * 3600)
        #expect(nights[0].hasAsleepSamples)
    }

    @Test func overlappingDuplicateSourcesAreCountedOnce() {
        // Apple Watch 与 iPhone 同时上报同一段睡眠：总量只能算一次。
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(20, 23), end: date(21, 3), stage: .core),
            .init(start: date(20, 23), end: date(21, 3), stage: .core),
            .init(start: date(21, 3), end: date(21, 7), stage: .rem)
        ], calendar: calendar)

        #expect(nights.count == 1)
        #expect(nights[0].asleepSeconds == 8 * 3600)
        #expect(nights[0].coverage(for: .core) == 4 * 3600)
        #expect(nights[0].coverage(for: .rem) == 4 * 3600)
    }

    @Test func overlappingStagesKeepCoverageSeparateFromTotal() {
        // 分期互相重叠时，总睡眠取并集；各分期覆盖单独统计，允许相加大于总时长。
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(20, 23), end: date(21, 5), stage: .core),
            .init(start: date(21, 3), end: date(21, 7), stage: .deep)
        ], calendar: calendar)

        #expect(nights[0].asleepSeconds == 8 * 3600)
        #expect(nights[0].coverage(for: .core) == 6 * 3600)
        #expect(nights[0].coverage(for: .deep) == 4 * 3600)
        #expect(nights[0].stagedSeconds == 10 * 3600)
    }

    @Test func awakeAndInBedAloneAreUnknownNotZeroHours() {
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(20, 22), end: date(21, 6), stage: .inBed),
            .init(start: date(21, 1), end: date(21, 2), stage: .awake)
        ], calendar: calendar)

        #expect(nights.count == 1)
        #expect(nights[0].asleepSeconds == 0)
        #expect(nights[0].hasAsleepSamples == false)
        #expect(nights[0].awakeSeconds == 3600)
    }

    @Test func crossMidnightSleepBelongsToTheWakeDay() {
        // 23:00 睡到次日 07:00，归到醒来的那天，整段都计入。
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(19, 23), end: date(20, 7), stage: .unspecified)
        ], calendar: calendar)

        #expect(nights.count == 1)
        #expect(nights[0].day == date(20, 0))
        #expect(nights[0].asleepSeconds == 8 * 3600)
    }

    @Test func zeroLengthAndInvertedIntervalsAreIgnored() {
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(20, 23), end: date(20, 23), stage: .core),
            .init(start: date(21, 7), end: date(21, 1), stage: .deep)
        ], calendar: calendar)

        #expect(nights.isEmpty)
    }

    @Test func nightsAreGroupedByWakeDayAndSortedNewestFirst() {
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(18, 23), end: date(19, 7), stage: .core),
            .init(start: date(20, 23), end: date(21, 7), stage: .core),
            .init(start: date(21, 13), end: date(21, 14), stage: .unspecified)
        ], calendar: calendar)

        #expect(nights.count == 2)
        #expect(nights[0].day == date(21, 0))
        #expect(nights[0].asleepSeconds == 9 * 3600)
        #expect(nights[1].day == date(19, 0))
        #expect(nights[1].asleepSeconds == 8 * 3600)
    }

    @Test func higherPrioritySourceWinsSleepConflicts() {
        // Watch 说睡着了，iPhone 同时说清醒：以优先级高的 Watch 为准。
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(20, 23), end: date(21, 7), stage: .core, sourcePriority: 20),
            .init(start: date(21, 2), end: date(21, 3), stage: .awake, sourcePriority: 10)
        ], calendar: calendar)

        #expect(nights[0].asleepSeconds == 8 * 3600)
        #expect(nights[0].awakeSeconds == 0)
    }

    @Test func lowerPrioritySourceFillsUnclaimedTime() {
        // 高优先级只覆盖 23-7，低优先级仍可补上 7-9。
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(20, 23), end: date(21, 7), stage: .core, sourcePriority: 20),
            .init(start: date(21, 6), end: date(21, 9), stage: .core, sourcePriority: 10)
        ], calendar: calendar)

        #expect(nights[0].asleepSeconds == 10 * 3600)
        #expect(nights[0].coverage(for: .core) == 10 * 3600)
    }

    @Test func higherPriorityAwakeBeatsLowerPrioritySleep() {
        // Watch 明确记录 3-4 清醒，iPhone 笼统报 23-7 睡着：清醒只能算 1 小时。
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(21, 3), end: date(21, 4), stage: .awake, sourcePriority: 20),
            .init(start: date(20, 23), end: date(21, 7), stage: .core, sourcePriority: 10)
        ], calendar: calendar)

        #expect(nights[0].asleepSeconds == 7 * 3600)
        #expect(nights[0].awakeSeconds == 1 * 3600)
        #expect(nights[0].coverage(for: .core) == 7 * 3600)
    }

    @Test func samePriorityOverlapStillDeduplicates() {
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(20, 23), end: date(21, 7), stage: .core, sourcePriority: 10),
            .init(start: date(20, 23), end: date(21, 7), stage: .core, sourcePriority: 10)
        ], calendar: calendar)

        #expect(nights[0].asleepSeconds == 8 * 3600)
    }

    @Test func higherPriorityStageClipsLowerPriorityStageCoverage() {
        // 高优先级的 core 覆盖会裁掉低优先级 deep 的重叠部分。
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(20, 23), end: date(21, 5), stage: .core, sourcePriority: 20),
            .init(start: date(21, 3), end: date(21, 7), stage: .deep, sourcePriority: 10)
        ], calendar: calendar)

        #expect(nights[0].asleepSeconds == 8 * 3600)
        #expect(nights[0].coverage(for: .core) == 6 * 3600)
        #expect(nights[0].coverage(for: .deep) == 2 * 3600)
    }

    private var shanghaiCalendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }

    @Test func afternoonNapIsSeparatedFromNightSleep() {
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(20, 23), end: date(21, 7), stage: .core),
            .init(start: date(21, 13), end: date(21, 13, 30), stage: .unspecified)
        ], calendar: calendar)

        #expect(nights.count == 1)
        #expect(nights[0].asleepSeconds == 8.5 * 3600)
        #expect(nights[0].napSeconds == 0.5 * 3600)
        #expect(nights[0].nightSeconds == 8 * 3600)
    }

    @Test func shortEarlyMorningSleepIsNotANap() {
        // 凌晨 3 点的两小时是夜间睡眠，不会因为“短”就被算成午睡。
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(21, 3), end: date(21, 5), stage: .core)
        ], calendar: calendar)

        #expect(nights[0].napSeconds == 0)
        #expect(nights[0].nightSeconds == 2 * 3600)
    }

    @Test func longDaytimeSleepIsNotANap() {
        // 白天超过 3 小时的连续睡眠按夜间睡眠口径处理。
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(21, 13), end: date(21, 17, 30), stage: .core)
        ], calendar: calendar)

        #expect(nights[0].napSeconds == 0)
    }

    @Test func multipleNapsAddUpWithoutDoubleCounting() {
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(21, 13), end: date(21, 13, 20), stage: .unspecified),
            .init(start: date(21, 16), end: date(21, 16, 40), stage: .unspecified)
        ], calendar: calendar)

        #expect(nights[0].asleepSeconds == 3600)
        #expect(nights[0].napSeconds == 3600)
    }

    @Test func napThresholdComesFromThePolicy() {
        let samples = [ObservedSleepInterval(start: date(21, 13), end: date(21, 15), stage: .core)]
        let defaultNight = SleepNightAggregator.aggregate(samples, calendar: calendar)[0]
        #expect(defaultNight.napSeconds == 2 * 3600)

        let strict = SleepNightPolicy(napMaximumDuration: 3600)
        let strictNight = SleepNightAggregator.aggregate(samples, calendar: calendar, policy: strict)[0]
        #expect(strictNight.napSeconds == 0)
    }

    @Test func policyVersionAndTimeZoneAreRecorded() {
        let nights = SleepNightAggregator.aggregate([
            .init(start: date(20, 23), end: date(21, 7), stage: .core)
        ], calendar: shanghaiCalendar)

        #expect(nights[0].policyVersion == .v1)
        #expect(nights[0].timeZoneIdentifier == "Asia/Shanghai")
    }

    @Test func sameSampleBucketsByTheCallerTimeZone() {
        // 结束于 UTC 20:00：UTC 归 20 日，东八区已是 21 日凌晨，归到 21 日。
        let end = Date(timeIntervalSince1970: 1_792_526_400) // 2026-10-20T20:00:00Z
        let sample = ObservedSleepInterval(
            start: end.addingTimeInterval(-2 * 3600), end: end, stage: .core
        )
        let utcNight = SleepNightAggregator.aggregate([sample], calendar: calendar)[0]
        let shanghaiNight = SleepNightAggregator.aggregate([sample], calendar: shanghaiCalendar)[0]

        #expect(utcNight.day != shanghaiNight.day)
        #expect(shanghaiNight.timeZoneIdentifier == "Asia/Shanghai")
    }

    @Test func unionHandlesNestedAndAdjacentIntervals() {
        let base = date(20, 0)
        let total = SleepNightAggregator.unionSeconds([
            (base, base.addingTimeInterval(3600)),
            (base.addingTimeInterval(1800), base.addingTimeInterval(2400)),
            (base.addingTimeInterval(3600), base.addingTimeInterval(5400))
        ])
        #expect(total == 5400)
    }
}
