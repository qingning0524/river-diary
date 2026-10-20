import Foundation
import Combine

/// Private, local drafts. This directory is never part of replication or a backup export.
@MainActor
final class RiverLocalDraftStore: ObservableObject {
    enum Kind: String, Codable { case journal, question }
    private struct Draft: Codable { let dayKey: String; let kind: Kind; let text: String; var moodScore: Int?; var ratingEnabled: Bool? }
    private let directory: URL
    private var pending: [String: Draft] = [:]
    private var writes: [String: Task<Void, Never>] = [:]
    @Published private(set) var lastError: String?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RiverDiary/Drafts", isDirectory: true)
    }
    func text(for day: String, kind: Kind) -> String? {
        guard let file = file(for: day, kind: kind) else { return nil }
        if let draft = pending[file.lastPathComponent] { return draft.text }
        guard let bytes = try? Data(contentsOf: file), let draft = try? JSONDecoder().decode(Draft.self, from: bytes),
              draft.dayKey == day, draft.kind == kind else { return nil }
        return draft.text
    }
    func rating(for day: String) -> (enabled: Bool, score: Int)? {
        guard let file = file(for: day, kind: .journal) else { return nil }
        let draft = pending[file.lastPathComponent] ?? (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Draft.self, from: $0) }
        guard let draft, draft.dayKey == day, draft.kind == .journal, let enabled = draft.ratingEnabled else { return nil }
        return (enabled, draft.moodScore ?? 70)
    }
    func update(_ text: String, for day: String, kind: Kind, moodScore: Int? = nil, ratingEnabled: Bool? = nil) {
        guard let file = file(for: day, kind: kind) else { return }
        let key = file.lastPathComponent
        pending[key] = Draft(dayKey: day, kind: kind, text: text, moodScore: moodScore, ratingEnabled: ratingEnabled)
        writes[key]?.cancel()
        writes[key] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.write(key)
        }
    }
    func flush() {
        for work in writes.values { work.cancel() }
        writes.removeAll()
        for key in Array(pending.keys) { write(key) }
    }
    func remove(for day: String, kind: Kind) {
        guard let file = file(for: day, kind: kind) else { return }
        let key = file.lastPathComponent
        writes.removeValue(forKey: key)?.cancel(); pending.removeValue(forKey: key)
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            lastError = nil
        } catch { lastError = "草稿暂时无法清理，已保存的正式记录不受影响。" }
    }
    private func file(for day: String, kind: Kind) -> URL? {
        guard day.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return nil }
        return directory.appendingPathComponent("\(kind.rawValue)-\(day).json")
    }
    private func write(_ key: String) {
        guard let draft = pending[key], let file = file(for: draft.dayKey, kind: draft.kind) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try JSONEncoder().encode(draft).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            pending.removeValue(forKey: key); writes.removeValue(forKey: key); lastError = nil
        } catch { lastError = "草稿暂未写入本机。请使用保存按钮保留内容。" }
    }

    // MARK: - River conversations

    /// Chat history lives in the same protected, never-replicated directory as
    /// drafts: a conversation restarts the app as itself, not as cloud state.
    func conversation<Payload: Decodable>(for day: String, as type: Payload.Type) -> Payload? {
        guard let file = conversationFile(for: day) else { return nil }
        guard let bytes = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: bytes)
    }

    func saveConversation<Payload: Encodable>(_ value: Payload, for day: String) {
        guard let file = conversationFile(for: day) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { lastError = "对话暂未保存到本机；本次会话仍可继续。" }
    }

    private func conversationFile(for day: String) -> URL? {
        guard day.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return nil }
        return directory.appendingPathComponent("chat-\(day).json")
    }
}
