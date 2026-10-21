#if DEBUG
import Foundation
import RiverDiaryCore

/// 仅 Debug、且显式 `RIVER_DIARY_DEMO_SEED=1` 时使用；为截图/演示视频
/// 在隔离用户目录里生成几条合成记录，绝不接触正式资料。
@MainActor
enum MacDemoSeed {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["RIVER_DIARY_DEMO_SEED"] == "1"
    }

    static func seedIfNeeded(diary: DiaryStore, v2: V2Store) {
        guard isRequested, diary.entries.isEmpty else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let samples: [(offset: Int, text: String, mood: Int, capture: String, goal: String)] = [
            (0, "上午把桌面端的时间线收拢了一下。下午去河边走了二十分钟，风比昨天轻。", 7,
             "河边的风很轻，走了二十分钟。", "把今天最重要的一件事做完"),
            (1, "读完一章，记下三句话。晚上给自己煮了面，没有加班。", 6,
             "读完一章，留下三句话。", "读二十页书"),
            (2, "把旧照片整理进「记忆」，发现去年今天也在下雨。", 5,
             "去年今天也在下雨。", "整理十张旧照片")
        ]
        for sample in samples {
            guard let date = calendar.date(byAdding: .day, value: -sample.offset, to: today) else { continue }
            let entry = diary.entry(for: date)
            try? diary.saveWriting(entry: entry, text: sample.text, mood: sample.mood)
            _ = diary.addQuickCapture(sample.capture, for: date)
            try? diary.saveDailyGoal(DailyGoal(title: sample.goal, isCompleted: sample.offset == 0), for: date)
            let event = RawEvent(
                timestamp: date.addingTimeInterval(10 * 3600),
                source: .ingestion,
                kind: .ingestionSnapshot,
                payload: RawEventPayload(text: sample.capture)
            )
            _ = v2.insertRawEvent(event)
        }
    }
}
#endif
