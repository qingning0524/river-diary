import Foundation

/// One life fragment per card. A current AI interpretation replaces only fully covered raw rows.
enum RiverFootprintPresentation {
    static func chronology(_ rows: [IOSActivityRow], filter: FootprintFilter = .all) -> [IOSActivityRow] {
        let timed = rows.filter { !["全天", "当天手记"].contains($0.timeLabel ?? "") }
        let facts = timed.filter { $0.kind != .riverInsight && filter.matches($0.kind) }
        guard filter == .all else { return facts.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date } }
        let stories = timed.filter {
            $0.kind == .riverInsight && !$0.eventIDs.isEmpty && !$0.sourceLabel.contains("依据有更新") && !$0.sourceLabel.contains("等待其他设备")
        }
        let covered = Set(stories.flatMap(\.eventIDs))
        let remaining = facts.filter { $0.eventIDs.isEmpty || !Set($0.eventIDs).isSubset(of: covered) }
        return (stories + remaining).sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
}

