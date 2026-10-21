import Testing
@testable import RiverDiaryCore

struct SelfReportConsistencyTests {
    private func observation(_ report: String, _ facts: SelfReportFacts) -> String? {
        SelfReportConsistency.observation(selfReport: report, facts: facts)
    }

    @Test func sleepClaimAgainstShortSleepGetsOneNonJudgmentalSentence() {
        let message = observation("昨晚睡得很好，今天有精神。", SelfReportFacts(sleepHours: 4.2))
        #expect(message == "你写到“睡得很好”，而当天睡眠记录是 4.2 小时，可以放在一起看看。")
        #expect(message?.filter { $0 == "。" }.count == 1)
        #expect(message?.contains("撒谎") == false)
        #expect(message?.contains("但是") == false)
    }

    @Test func sleepClaimWithoutContradictionStaysSilent() {
        #expect(observation("睡够了，今天慢慢来。", SelfReportFacts(sleepHours: 7.5)) == nil)
        #expect(observation("睡得很好。", SelfReportFacts(sleepHours: 5.0)) == nil)
    }

    @Test func negatedSleepClaimIsNotTreatedAsPositive() {
        #expect(observation("昨晚没睡得很好，四点多就醒了。", SelfReportFacts(sleepHours: 4.0)) == nil)
        #expect(observation("不觉得睡得很好。", SelfReportFacts(sleepHours: 4.0)) == nil)
    }

    @Test func stepClaimAgainstLowStepCountGetsASentence() {
        let message = observation("今天走了很多路，腿都酸了。", SelfReportFacts(steps: 820))
        #expect(message == "你写到“走了很多路”，而当天步数记录是 820 步，可以放在一起看看。")
    }

    @Test func screenClaimAgainstHighScreenTimeGetsASentence() {
        let message = observation("今天很少看屏幕，一直在看书。", SelfReportFacts(screenMinutes: 450))
        #expect(message == "你写到“很少看屏幕”，而当天屏幕记录约 7.5 小时，可以放在一起看看。")
    }

    @Test func nothingDoneClaimAgainstCompletedItemsGetsASentence() {
        let message = observation("今天什么都没做，有点浪费。", SelfReportFacts(completedItems: 3))
        #expect(message == "你写到“什么都没做”，而记录里有 3 项完成事项，可以放在一起看看。")
    }

    @Test func noObjectiveFactsMeansNoObservation() {
        #expect(observation("今天什么都没做。", SelfReportFacts()) == nil)
        #expect(observation("今天走了很多。", SelfReportFacts(sleepHours: 4.0)) == nil)
    }

    @Test func thresholdsAreConservativeAtTheBoundary() {
        #expect(observation("今天什么都没做。", SelfReportFacts(completedItems: 2)) == nil)
        #expect(observation("今天走了很多。", SelfReportFacts(steps: 1_500)) == nil)
        #expect(observation("今天很少看屏幕。", SelfReportFacts(screenMinutes: 359)) == nil)
    }

    @Test func onlyOneSentenceEvenWhenSeveralFactsContradict() {
        let message = observation(
            "昨晚睡得很好，今天走了很多，也没怎么碰手机，但什么都没做。",
            SelfReportFacts(sleepHours: 3.0, steps: 200, screenMinutes: 600, completedItems: 4)
        )
        #expect(message?.filter { $0 == "。" }.count == 1)
        #expect(message?.contains("完成事项") == true)
    }

    @Test func doubleNegationDoesNotBecomeAClaim() {
        #expect(observation("并不是什么都没做，整理了两张表。", SelfReportFacts(completedItems: 4)) == nil)
    }

    @Test func ordinaryTirednessWithoutAClaimStaysSilent() {
        #expect(observation("今天很累，但也不知道忙了什么。", SelfReportFacts(sleepHours: 4.0, steps: 300)) == nil)
    }
}
