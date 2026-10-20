import Foundation

/// Pure presentation rules for the Memory Browser. It owns matching and scope
/// behavior so the SwiftUI view only renders the result.
enum MemoryScope: String, CaseIterable, Identifiable {
    case all, durable, reflections, archive, favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .durable: "长期记忆"
        case .reflections: "回顾与河流信"
        case .archive: "日期档案"
        case .favorites: "收藏"
        }
    }
}

enum MemoryPresentation {
    enum Section: Hashable {
        case durable, reflections, archive
    }

    static func sections(for scope: MemoryScope) -> [Section] {
        switch scope {
        case .all: [.durable, .reflections, .archive]
        case .durable: [.durable]
        case .reflections: [.reflections]
        case .archive: [.archive]
        case .favorites: [.reflections, .archive]
        }
    }

    static func durableMemories(_ memories: [Memory], query: String) -> [Memory] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return memories }
        return memories.filter {
            [$0.title, $0.body, $0.kind.displayName].joined(separator: " ").localizedStandardContains(needle)
        }
    }

    static func reflections(_ letters: [MonthlyLetter], scope: MemoryScope, query: String) -> [MonthlyLetter] {
        let source = scope == .favorites ? letters.filter(\.isFavorite) : letters
        let needle = normalized(query)
        guard !needle.isEmpty else { return source }
        return source.filter {
            [$0.title, $0.body, $0.evidence, $0.month].joined(separator: " ").localizedStandardContains(needle)
        }
    }

    static func archiveDays(_ days: [MemoryArchiveDay], scope: MemoryScope, favoriteDates: Set<String>, query: String) -> [MemoryArchiveDay] {
        let source = scope == .favorites ? days.filter { favoriteDates.contains($0.id) } : days
        let needle = normalized(query)
        return source
            .filter { needle.isEmpty || $0.matches(needle) }
            .sorted { $0.id > $1.id }
    }

    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
