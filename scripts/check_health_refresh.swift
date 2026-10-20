import Foundation

@main
struct HealthRefreshChecks {
    static func main() {
        var batch = HealthRefreshBatch()
        let first = batch.begin()!
        precondition(batch.isLoading)
        precondition(batch.begin() == nil, "Concurrent refreshes must coalesce")
        precondition(!batch.finish(.sleep, generation: first))
        precondition(!batch.finish(.sleep, generation: first), "A duplicate sleep result is not a complete snapshot")
        precondition(batch.isLoading, "Loading must include exercise queries")
        precondition(batch.finish(.exercise, generation: first))
        precondition(!batch.isLoading)
        precondition(!batch.finish(.exercise, generation: first), "Completion is emitted exactly once")
        let next = batch.begin()!
        precondition(!batch.accepts(first))
        precondition(!batch.finish(.sleep, generation: first), "Old callbacks cannot complete the new batch")
        precondition(!batch.finish(.exercise, generation: next))
        precondition(batch.finish(.sleep, generation: next), "Either query order is supported")
        print("HEALTH_REFRESH_CHECKS_OK: overlap, complete snapshot, duplicate and stale callbacks")
    }
}
