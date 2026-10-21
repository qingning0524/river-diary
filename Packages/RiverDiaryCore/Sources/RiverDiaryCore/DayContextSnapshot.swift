import Foundation

/// 一台设备某一天的“上下文快照”。它是给其他端和网页看的投影，
/// 不是新的事实库：原始证据仍在 Event/Operation 里。
///
/// 敏感边界：快照只放用户可读的摘要、标题、计数和短摘录；不放 URL 全量、
/// 备忘录全文、照片、健康原始样本。需要全文时再逐来源打开。
public struct DayContextSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var deviceID: String
    public var deviceName: String
    public var day: String
    public var generatedAt: Date
    public var sections: [DayContextSection]

    public var id: String { "\(deviceID)|\(day)" }

    public init(
        deviceID: String,
        deviceName: String,
        day: String,
        generatedAt: Date = Date(),
        sections: [DayContextSection]
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.day = day
        self.generatedAt = generatedAt
        self.sections = sections
    }

    public var isEmpty: Bool { sections.isEmpty }

    public var summaryLine: String {
        sections.map(\.summary).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 给现有全文检索/事件文本用的可读摘要；不替代 contextJSON。
    public var searchText: String {
        let items = sections.flatMap { section in
            section.items.prefix(5).compactMap { item -> String? in
                let detail = item.detail.map { String($0.prefix(200)) }
                let line = [item.title, detail].compactMap { $0 }.joined(separator: " · ")
                return line.isEmpty ? nil : line
            }
        }
        return ([summaryLine] + items).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decodeJSON(_ json: String) -> DayContextSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(DayContextSnapshot.self, from: data)
    }
}

public struct DayContextSection: Codable, Sendable, Equatable, Identifiable {
    /// browser / notes / markdown / kindle / calendar / weather / git /
    /// focus / health / workout / stateOfMind / screenTime / voice / apps
    public var kind: String
    public var title: String
    public var summary: String
    public var items: [DayContextItem]

    public var id: String { kind }

    public init(kind: String, title: String, summary: String, items: [DayContextItem] = []) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.items = items
    }
}

public struct DayContextItem: Codable, Sendable, Equatable {
    public var title: String
    public var detail: String?
    public var count: Int?
    public var at: Date?

    public init(title: String, detail: String? = nil, count: Int? = nil, at: Date? = nil) {
        self.title = title
        self.detail = detail
        self.count = count
        self.at = at
    }
}
