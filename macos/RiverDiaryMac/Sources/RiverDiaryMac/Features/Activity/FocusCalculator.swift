import Foundation

/// 一段连续专注。
struct FocusBlock: Equatable, Identifiable {
    var start: Date
    var end: Date
    var minutes: Int

    var id: Date { start }
}

/// 从应用片段推导“专注段”，而不是把“工作类应用的总时长”直接叫专注。
///
/// 规则：
/// - 只把工作/学习/创作类片段计入专注时长；
/// - 相邻片段间隔 ≤5 分钟算同一次；
/// - 短暂切到沟通/浏览（<5 分钟）不打断这一次，但也不计入专注时长；
/// - 累计专注 ≥25 分钟才成立。
enum FocusCalculator {
    static let minimumMinutes = 25
    static let maximumGap: TimeInterval = 5 * 60
    static let maximumDistraction: TimeInterval = 5 * 60

    static func blocks(
        from sessions: [ActivitySession],
        minimumMinutes: Int = minimumMinutes,
        maximumGap: TimeInterval = maximumGap
    ) -> [FocusBlock] {
        let ordered = sessions.sorted { $0.start < $1.start }
        var result: [FocusBlock] = []
        var runStart: Date?
        var runEnd: Date?
        var focusSeconds: TimeInterval = 0

        func flush() {
            guard let start = runStart, let end = runEnd else { return }
            let minutes = Int(focusSeconds / 60)
            if minutes >= max(1, minimumMinutes), end > start {
                result.append(FocusBlock(start: start, end: end, minutes: minutes))
            }
            runStart = nil
            runEnd = nil
            focusSeconds = 0
        }

        for session in ordered {
            guard ActivityClassifier.isFocus(session.category) else {
                // 短打断不切段；真正离开专注状态才结束这一次。
                if session.duration >= maximumDistraction {
                    flush()
                }
                continue
            }

            if let end = runEnd, session.start.timeIntervalSince(end) <= maximumGap {
                let overlapStart = max(session.start, end)
                focusSeconds += max(0, session.end.timeIntervalSince(overlapStart))
                runEnd = max(end, session.end)
            } else {
                flush()
                runStart = session.start
                runEnd = session.end
                focusSeconds = session.duration
            }
        }

        flush()
        return result
    }
}
