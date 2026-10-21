import Foundation
import RiverDiaryCore

/// 把 Mac 当天的日记/活动事实映射成 Core 的规则输入。
/// 只做字段映射：缺失仍是 nil，不用 0 冒充“没有发生”。
enum SelfReportFactsBridge {
    static func facts(
        entry: DiaryEntry,
        pipelineAvailable: Bool,
        pipelineTotal: TimeInterval
    ) -> SelfReportFacts {
        let health = entry.health
        let screenMinutes: Int?
        if pipelineAvailable, pipelineTotal > 0 {
            screenMinutes = Int((pipelineTotal / 60).rounded())
        } else if let hours = entry.screenHours {
            screenMinutes = Int((hours * 60).rounded())
        } else {
            screenMinutes = nil
        }
        let completed = (entry.didItems ?? [])
            .flatMap { $0.items ?? [] }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        return SelfReportFacts(
            sleepHours: health?.resolvedSleepHours,
            steps: health?.steps,
            screenMinutes: screenMinutes,
            completedItems: completed
        )
    }
}
