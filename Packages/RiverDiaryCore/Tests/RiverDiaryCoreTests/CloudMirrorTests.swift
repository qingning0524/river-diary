import Foundation
import Testing
@testable import RiverDiaryCore

struct CloudMirrorTests {
    private func archive(includeHealth: Bool = false) -> MemoryMirrorArchive {
        var contexts: [DayContextSnapshot] = [
            DayContextSnapshot(
                deviceID: "device-mac", deviceName: "Mac", day: "2026-10-21",
                sections: [
                    DayContextSection(kind: "notes", title: "备忘录", summary: "1 条", items: [
                        DayContextItem(title: "窗边", detail: "去河边走走。"),
                    ]),
                ]
            ),
        ]
        if includeHealth {
            contexts.append(
                DayContextSnapshot(
                    deviceID: "device-iphone", deviceName: "iPhone", day: "2026-10-22",
                    sections: [
                        DayContextSection(kind: "health", title: "睡眠", summary: "7.2 小时"),
                        DayContextSection(kind: "workout", title: "活动", summary: "8,412 步"),
                    ]
                )
            )
        }
        return MemoryMirrorArchive(
            exportedAt: "2026-10-22T00:00:00Z",
            persona: MemoryMirrorPersona(name: "林岸"),
            entries: [
                MemoryMirrorEntry(
                    id: "e1", occurredAt: "2026-10-21T07:20:00", kind: "journal",
                    title: "早上的水", body: "烧水的时候想起你。", place: "厨房",
                    source: MemoryMirrorSource(type: "user", label: "原生日记")
                ),
                MemoryMirrorEntry(
                    id: "e2", occurredAt: "2026-10-22T18:10:00", kind: "journal",
                    title: "沿河走", body: "风从桥下过来。", place: "河边",
                    source: MemoryMirrorSource(type: "user", label: "原生日记")
                ),
            ],
            contexts: contexts,
            collections: [MemoryMirrorCollection(id: "c1", title: "秋天")],
            understandings: [MemoryMirrorUnderstanding(id: "u1", statement: "你常在水边停下来。")]
        )
    }

    @Test func envelopeRoundTripsAndSummaryCountsWithoutPlaintext() throws {
        let envelope = try CloudMirrorCrypto.buildEnvelope(
            archive: archive(), passphrase: "correct horse battery",
            now: Date(timeIntervalSince1970: 1_790_000_000), iterations: 100_000
        )
        #expect(envelope.summary.entries == 2)
        #expect(envelope.summary.days == 2)
        #expect(envelope.summary.places == 2)
        #expect(envelope.summary.collections == 1)
        #expect(envelope.summary.understandings == 1)
        #expect(envelope.summary.first == "2026-10-21")
        #expect(envelope.summary.last == "2026-10-22")
        #expect(envelope.summary.includesHealth == false)
        #expect(!envelope.ciphertext.contains("烧水"))
        let decoded = try CloudMirrorCrypto.decrypt(envelope, passphrase: "correct horse battery")
        #expect(decoded.entries.map(\.title) == ["早上的水", "沿河走"])
        #expect(decoded.entries[0].body == "烧水的时候想起你。")
        #expect(decoded.contexts.first?.sections.first?.kind == "notes")
        #expect(decoded.persona?.name == "林岸")
    }

    @Test func wrongPassphraseAndTamperingFailClosed() throws {
        let envelope = try CloudMirrorCrypto.buildEnvelope(
            archive: archive(), passphrase: "correct horse battery", iterations: 100_000
        )
        #expect(throws: CloudMirrorError.badPassphrase) {
            _ = try CloudMirrorCrypto.decrypt(envelope, passphrase: "wrong horse battery")
        }
        var tampered = envelope
        tampered.ciphertext = Data(repeating: 7, count: 48).base64EncodedString()
        #expect(throws: CloudMirrorError.badPassphrase) {
            _ = try CloudMirrorCrypto.decrypt(tampered, passphrase: "correct horse battery")
        }
    }

    @Test func healthSectionsRequireExplicitConsent() throws {
        let defaultEnvelope = try CloudMirrorCrypto.buildEnvelope(
            archive: archive(includeHealth: true), passphrase: "correct horse battery", iterations: 100_000
        )
        #expect(defaultEnvelope.summary.includesHealth == false)
        #expect(!defaultEnvelope.ciphertext.contains("7.2"))
        let defaultArchive = try CloudMirrorCrypto.decrypt(defaultEnvelope, passphrase: "correct horse battery")
        #expect(defaultArchive.contexts.count == 1)
        #expect(defaultArchive.contexts[0].sections.map(\.kind) == ["notes"])

        let consented = try CloudMirrorCrypto.buildEnvelope(
            archive: archive(includeHealth: true), passphrase: "correct horse battery",
            includeHealth: true, iterations: 100_000
        )
        #expect(consented.summary.includesHealth == true)
        let consentedArchive = try CloudMirrorCrypto.decrypt(consented, passphrase: "correct horse battery")
        #expect(consentedArchive.contexts.count == 2)
        #expect(consentedArchive.contexts[1].sections.map(\.kind) == ["health", "workout"])
    }

    @Test func passphrasePolicyIsEnforced() {
        #expect(throws: CloudMirrorError.passphraseTooShort) {
            _ = try CloudMirrorCrypto.buildEnvelope(archive: archive(), passphrase: "short", iterations: 100_000)
        }
        #expect(throws: CloudMirrorError.passphraseTooLong) {
            _ = try CloudMirrorCrypto.buildEnvelope(
                archive: archive(), passphrase: String(repeating: "长", count: 129), iterations: 100_000
            )
        }
    }

    @Test func aSecondCleanDirectoryCanOpenTheCiphertext() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("river-cloud-interop-\(UUID().uuidString)", isDirectory: true)
        let deviceA = root.appendingPathComponent("device-a", isDirectory: true)
        let deviceB = root.appendingPathComponent("device-b", isDirectory: true)
        try fm.createDirectory(at: deviceA, withIntermediateDirectories: true)
        try fm.createDirectory(at: deviceB, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let envelope = try CloudMirrorCrypto.buildEnvelope(
            archive: archive(includeHealth: true), passphrase: "correct horse battery",
            includeHealth: true, iterations: 100_000
        )
        let wire = try JSONEncoder().encode(envelope)
        #expect(!wire.contains("烧水".data(using: .utf8)!))
        let uploaded = deviceA.appendingPathComponent("cloud-envelope.json")
        try wire.write(to: uploaded)

        // The second directory has no local archive, key, or state: only the
        // bytes a server would hand back.
        let downloaded = deviceB.appendingPathComponent("cloud-envelope.json")
        try fm.copyItem(at: uploaded, to: downloaded)
        let received = try JSONDecoder().decode(CloudMirrorEnvelope.self, from: Data(contentsOf: downloaded))
        #expect(received.summary.includesHealth == true)
        let decoded = try CloudMirrorCrypto.decrypt(received, passphrase: "correct horse battery")
        #expect(decoded.entries.map(\.body) == ["烧水的时候想起你。", "风从桥下过来。"])
        #expect(decoded.contexts.flatMap(\.sections).contains { $0.kind == "health" })
        #expect(throws: CloudMirrorError.badPassphrase) {
            _ = try CloudMirrorCrypto.decrypt(received, passphrase: "wrong horse battery")
        }
    }

    @Test func decodesLegacyEnvelopesWithoutConsentMetadata() throws {
        let fixture = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/web-cloud-envelope.json"))
        var object = try JSONSerialization.jsonObject(with: fixture) as! [String: Any]
        var summary = object["summary"] as! [String: Any]
        summary.removeValue(forKey: "includes_health")
        object["summary"] = summary
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let envelope = try JSONDecoder().decode(CloudMirrorEnvelope.self, from: legacy)
        #expect(envelope.summary.includesHealth == false)
        #expect(try CloudMirrorCrypto.decrypt(envelope, passphrase: "correct horse battery").entries.count == 1)
    }

    @Test func decryptsAnEnvelopeProducedByTheWebConsole() throws {
        let fixture = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/web-cloud-envelope.json"))
        let envelope = try JSONDecoder().decode(CloudMirrorEnvelope.self, from: fixture)
        let decoded = try CloudMirrorCrypto.decrypt(envelope, passphrase: "correct horse battery")
        #expect(decoded.entries.count == 1)
        #expect(decoded.entries[0].title == "网页端的河")
        #expect(decoded.contexts.first?.sections.first?.kind == "notes")
    }
}
