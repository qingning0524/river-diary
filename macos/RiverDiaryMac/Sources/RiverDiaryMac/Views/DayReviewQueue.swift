import Foundation

/// Both day layouts use the same date-scoped queue, excluding items already in
/// the cross-date confirmation centre. Empty local queues add no competing card.
enum DayReviewQueue {
    static func items(in timeline: ActivityTimeline, clarificationIDs: Set<String>,
                      excluding sharedTargetIDs: Set<String>, limit: Int = 4) -> [ActivityTimelineItem] {
        Array(timeline.foldedItems.filter { item in
            let identifiers = Set([item.id, item.annotationKey].compactMap { $0 })
            return identifiers.isDisjoint(with: sharedTargetIDs)
                && (item.needsReview || clarificationIDs.contains(item.id))
        }.sorted { $0.reviewSpan > $1.reviewSpan }.prefix(max(0, limit)))
    }
}
