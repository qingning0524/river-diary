import Foundation

/// A read-only, user-initiated export for the web memory console.
///
/// This is deliberately a small, stable envelope rather than the app's private
/// backup format. It carries diary entries the user can already read on this
/// device; it never includes encryption keys, raw machine observations, photo
/// bytes, or health source data.
public struct MemoryMirrorArchive: Codable, Equatable, Sendable {
    public static let currentFormat = "river.memory-mirror"
    public static let currentVersion = 2

    public var format: String
    public var version: Int
    public var exportedAt: String
    public var persona: MemoryMirrorPersona?
    public var entries: [MemoryMirrorEntry]
    /// v2: 双端设备日上下文；网页会把它映射成只读 context entries。
    public var contexts: [DayContextSnapshot]
    public var collections: [MemoryMirrorCollection]
    public var understandings: [MemoryMirrorUnderstanding]

    enum CodingKeys: String, CodingKey {
        case format, version, exportedAt = "exported_at", persona, entries, contexts, collections, understandings
    }

    public init(
        format: String = MemoryMirrorArchive.currentFormat,
        version: Int = MemoryMirrorArchive.currentVersion,
        exportedAt: String,
        persona: MemoryMirrorPersona? = nil,
        entries: [MemoryMirrorEntry],
        contexts: [DayContextSnapshot] = [],
        collections: [MemoryMirrorCollection] = [],
        understandings: [MemoryMirrorUnderstanding] = []
    ) {
        self.format = format
        self.version = version
        self.exportedAt = exportedAt
        self.persona = persona
        self.entries = entries
        self.contexts = contexts
        self.collections = collections
        self.understandings = understandings
    }

    /// Converts the readable `DiaryData` JSON already used by both apps into
    /// the web mirror envelope. The converter intentionally ignores unknown
    /// fields and never invents entries from an empty archive.
    public static func legacy(
        fromDiaryJSON data: Data,
        personaName: String? = nil,
        exportedAt: Date = Date()
    ) throws -> MemoryMirrorArchive {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawEntries = root["entries"] as? [[String: Any]] else {
            throw MemoryMirrorExportError.invalidDiary
        }

        var seenIDs = Set<String>()
        var entries: [MemoryMirrorEntry] = []
        for (index, raw) in rawEntries.enumerated() {
            guard let date = normalizedDate(string(raw["date"]) ?? string(raw["page_id"])) else { continue }
            let baseID = string(raw["page_id"]) ?? date
            var id = baseID
            if seenIDs.contains(id) { id = "\(baseID)-\(index)" }
            seenIDs.insert(id)

            let thoughts = strings(raw["thoughts"])
            let overview = string(raw["overview"])
            let daily = string(raw["daily"])
            let memos = strings(raw["memos"])
            let plan = string(raw["plan"])
            let workBuddy = string(raw["work_buddy"])
            let bodyParts = orderedUnique(
                [thoughts.joined(separator: "\n"), overview, daily, memos.joined(separator: "\n"), plan, workBuddy]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            let body = bodyParts.joined(separator: "\n\n")
            let facts = didItems(raw["did"])
            let tags = orderedUnique(strings(raw["tags"]))
            let metrics = raw["metrics"] as? [String: Any]
            let mood = string(raw["mood"]) ?? number(metrics?["mood"]).map { String(format: "%.1f", $0) }
            let title = string(raw["title"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTitle = body.split(separator: "\n").first.map(String.init) ?? date
            let hasWriting = !body.isEmpty

            entries.append(MemoryMirrorEntry(
                id: id,
                occurredAt: "\(date)T12:00:00",
                kind: hasWriting ? "journal" : "auto",
                title: title?.isEmpty == false ? title! : String(fallbackTitle.prefix(28)),
                body: body,
                facts: facts,
                tags: tags,
                place: nil,
                mood: mood,
                weather: nil,
                source: MemoryMirrorSource(type: hasWriting ? "user" : "auto", label: hasWriting ? "原生日记" : "自动整理"),
                favorite: false,
                collectionIds: [],
                tone: nil
            ))
        }

        guard !entries.isEmpty else { throw MemoryMirrorExportError.emptyDiary }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let persona = personaName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MemoryMirrorArchive(
            exportedAt: formatter.string(from: exportedAt),
            persona: persona?.isEmpty == false ? MemoryMirrorPersona(name: persona!) : nil,
            entries: entries.sorted { $0.occurredAt < $1.occurredAt }
        )
    }

    /// Contexts-only export: used when the user has Mac/iPhone context but no
    /// legacy diary entry on this device.
    public static func empty(exportedAt: Date = Date()) -> MemoryMirrorArchive {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return MemoryMirrorArchive(exportedAt: formatter.string(from: exportedAt), entries: [])
    }

    /// v2: stores structured device contexts alongside diary entries. The web
    /// console maps them into read-only `kind=context` cards.
    public func appendingContexts(_ snapshots: [DayContextSnapshot]) -> MemoryMirrorArchive {
        guard !snapshots.isEmpty else { return self }
        var seen = Set(contexts.map(\.id))
        var merged = contexts
        for snapshot in snapshots where !snapshot.isEmpty {
            guard seen.insert(snapshot.id).inserted else { continue }
            merged.append(snapshot)
        }
        merged.sort { $0.day < $1.day }
        var copy = self
        copy.contexts = merged
        return copy
    }

    public static func contextEntry(from snapshot: DayContextSnapshot) -> MemoryMirrorEntry {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let occurredAt = snapshot.day + "T12:00:00"
        let sections = snapshot.sections.map { section -> String in
            var lines = ["\(section.title)：\(section.summary)"]
            lines += section.items.prefix(3).map { item in
                let detail = [item.title, item.detail, item.count.map { "\($0)" }]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                return "· \(detail)"
            }
            return lines.joined(separator: "\n")
        }
        let safeDeviceID = snapshot.deviceID.unicodeScalars.map { scalar -> Character in
            let value = scalar.value
            let allowed = (48...57).contains(value) || (65...90).contains(value)
                || (97...122).contains(value) || value == 45 || value == 95
            return allowed ? Character(String(scalar)) : "-"
        }.reduce(into: "") { $0.append($1) }
        return MemoryMirrorEntry(
            id: "context-\(safeDeviceID)-\(snapshot.day)",
            occurredAt: occurredAt,
            kind: "context",
            title: "\(snapshot.deviceName) 的一天",
            body: sections.joined(separator: "\n\n"),
            facts: snapshot.sections.flatMap { $0.items.map { "\($0.title) · \($0.detail ?? "")" } },
            tags: ["设备上下文", snapshot.deviceName],
            source: MemoryMirrorSource(type: "context", label: "\(snapshot.deviceName) 上下文"),
            tone: "dusk"
        )
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    private static func normalizedDate(_ value: String?) -> String? {
        guard let value, value.count >= 10 else { return nil }
        let date = String(value.prefix(10))
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1900...2100).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]) else {
            return nil
        }
        return date
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func strings(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { string($0) }
    }

    private static func didItems(_ value: Any?) -> [String] {
        guard let groups = value as? [[String: Any]] else { return [] }
        return groups.flatMap { strings($0["items"]) }
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

public struct MemoryMirrorPersona: Codable, Equatable, Sendable {
    public var name: String
    public init(name: String) { self.name = name }
}

public struct MemoryMirrorEntry: Codable, Equatable, Sendable {
    public var id: String
    public var occurredAt: String
    public var kind: String
    public var title: String
    public var body: String
    public var facts: [String]
    public var tags: [String]
    public var place: String?
    public var mood: String?
    public var weather: String?
    public var source: MemoryMirrorSource
    public var favorite: Bool
    public var collectionIds: [String]
    public var tone: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, facts, tags, place, mood, weather, source, favorite, tone
        case occurredAt = "occurred_at"
        case collectionIds = "collection_ids"
    }

    public init(
        id: String,
        occurredAt: String,
        kind: String,
        title: String,
        body: String,
        facts: [String] = [],
        tags: [String] = [],
        place: String? = nil,
        mood: String? = nil,
        weather: String? = nil,
        source: MemoryMirrorSource,
        favorite: Bool = false,
        collectionIds: [String] = [],
        tone: String? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
        self.title = title
        self.body = body
        self.facts = facts
        self.tags = tags
        self.place = place
        self.mood = mood
        self.weather = weather
        self.source = source
        self.favorite = favorite
        self.collectionIds = collectionIds
        self.tone = tone
    }
}

public struct MemoryMirrorSource: Codable, Equatable, Sendable {
    public var type: String
    public var label: String
    public init(type: String, label: String) { self.type = type; self.label = label }
}

public struct MemoryMirrorCollection: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var summary: String?
    public var entryIds: [String]
    public var coverTone: String?

    enum CodingKeys: String, CodingKey {
        case id, title, summary
        case entryIds = "entry_ids"
        case coverTone = "cover_tone"
    }

    public init(id: String, title: String, summary: String? = nil, entryIds: [String] = [], coverTone: String? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.entryIds = entryIds
        self.coverTone = coverTone
    }
}

public struct MemoryMirrorUnderstanding: Codable, Equatable, Sendable {
    public var id: String
    public var statement: String
    public var evidenceIds: [String]
    public var scope: String?
    public var status: String?
    public var correction: String?

    enum CodingKeys: String, CodingKey {
        case id, statement, scope, status, correction
        case evidenceIds = "evidence_ids"
    }

    public init(id: String, statement: String, evidenceIds: [String] = [], scope: String? = nil, status: String? = nil, correction: String? = nil) {
        self.id = id
        self.statement = statement
        self.evidenceIds = evidenceIds
        self.scope = scope
        self.status = status
        self.correction = correction
    }
}

public enum MemoryMirrorExportError: LocalizedError, Equatable {
    case invalidDiary
    case emptyDiary

    public var errorDescription: String? {
        switch self {
        case .invalidDiary: "日记 JSON 无法读取"
        case .emptyDiary: "没有可导出的日记"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
