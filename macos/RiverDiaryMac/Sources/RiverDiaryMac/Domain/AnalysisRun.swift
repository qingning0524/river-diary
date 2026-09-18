import Foundation

enum RiverTaskKind: String, Codable, Hashable, CaseIterable, Sendable {
    case summarize
    case weeklyReview
    case query
    case monthlyLetter
    case namingProposal
}

/// AI output, kept strictly outside the fact layer. An analysis run records
/// the context it read and the evidence that grounded it, but can never write
/// back to raw_events, activities, episodes, or memories.
struct AnalysisRun: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var task: RiverTaskKind
    var inputContextReference: UUID?
    var outputText: String
    var evidenceIDs: [UUID]
    var model: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        task: RiverTaskKind,
        inputContextReference: UUID? = nil,
        outputText: String = "",
        evidenceIDs: [UUID] = [],
        model: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.task = task
        self.inputContextReference = inputContextReference
        self.outputText = outputText
        self.evidenceIDs = evidenceIDs
        self.model = model
        self.createdAt = createdAt
    }
}
