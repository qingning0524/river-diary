import Foundation

/// One complete snapshot contains both queries. Duplicate or stale callbacks
/// cannot finish another refresh or publish a partial health snapshot.
struct HealthRefreshBatch {
    enum Part: Hashable { case sleep, exercise }
    private var generation: UUID?
    private var pending = Set<Part>()

    var isLoading: Bool { generation != nil }

    mutating func begin() -> UUID? {
        guard generation == nil else { return nil }
        let id = UUID()
        generation = id
        pending = [.sleep, .exercise]
        return id
    }

    func accepts(_ id: UUID) -> Bool { generation == id }

    mutating func finish(_ part: Part, generation id: UUID) -> Bool {
        guard generation == id, pending.remove(part) != nil else { return false }
        guard pending.isEmpty else { return false }
        generation = nil
        return true
    }
}
