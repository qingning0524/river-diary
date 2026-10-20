#if DEBUG
import Foundation
import CryptoKit
import RiverDiaryCore

/// Isolated QA only. Never available in a Release build or the production bundle.
@MainActor enum RiverModernQAFixtures {
    static func seedIfRequested(node: RiverNodeStore) {
        guard Bundle.main.bundleIdentifier == "studio.riverdiary.ios.qa",
              ProcessInfo.processInfo.arguments.contains("--riverdiary-qa-modern-fixtures"),
              !UserDefaults.standard.bool(forKey: "river.qa.modern.seeded"), let db = node.database else { return }
        do {
            let day = Calendar.current.startOfDay(for: .now)
            let note = try db.append(source: "manual", kind: "manual.note", payload: RiverEventPayload(text: "坐在窗边，慢慢把脑子里的想法写下来。"), observedAt: day.addingTimeInterval(9 * 3600))
            _ = try db.append(source: "shortcuts", kind: "app.opened", payload: RiverEventPayload(appName: "备忘录", bundleID: "com.apple.mobilenotes"), observedAt: day.addingTimeInterval(9 * 3600 + 600))
            _ = try db.append(source: "shortcuts", kind: "app.closed", payload: RiverEventPayload(appName: "备忘录", bundleID: "com.apple.mobilenotes"), observedAt: day.addingTimeInterval(9 * 3600 + 2700))
            if let journal = RiverSharedStateRecord.journalEntry(RiverJournalEntryContent(dayKey: RiverIOSProjection.dayKey(day), body: "没有急着开始工作。\n坐在窗边喝完一杯咖啡，慢慢把脑子里的想法写下来。", moodScore: 74)) { try db.saveSharedUserRecord(journal) }
            for (offset, body) in [(1, "傍晚，走了一条新路。\n沿着河边一直走，天色一点点暗下来。"), (2, "终于写完的那个下午。\n关掉文档的时候，窗外刚好亮起了灯。")] {
                guard let previous = Calendar.current.date(byAdding: .day, value: -offset, to: day), let record = RiverSharedStateRecord.journalEntry(RiverJournalEntryContent(dayKey: RiverIOSProjection.dayKey(previous), body: body, moodScore: 68 + offset, tags: offset == 2 ? ["river-favorite"] : [])) else { continue }
                try db.saveSharedUserRecord(record)
            }
            let choices = [RiverPlaceCandidate(name: "岸边咖啡", address: "临江路 18 号", provider: "qa", distanceMeters: 28, horizontalAccuracyMeters: 65), RiverPlaceCandidate(name: "北岸烘焙", address: "临江路 22 号", provider: "qa", distanceMeters: 46, horizontalAccuracyMeters: 65)]
            let place = RiverPendingConfirmationContent(title: "地点核对", question: "08:32—09:02，你在哪里停留？", detail: "定位范围约 ±65 米。附近有两个候选地点，尚不能确定实际到访。", evidenceRefs: [note.id.uuidString], targetType: "place", targetID: "qa-place", choices: choices)
            let fact = RiverPendingConfirmationContent(title: "事实核对", question: "今天上午，你是在备忘录里写日记吗？", detail: "使用应用不代表一定在写日记，需要你补上活动的真实含义。", candidate: "今天上午，你在备忘录里写了日记。", evidenceRefs: [note.id.uuidString], targetType: "fact")
            for (index, content) in [place, fact].enumerated() {
                let payload = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
                try db.saveSharedUserRecord(RiverSharedStateRecord(id: UUID(), kind: .pendingConfirmation, status: "pending", logicalKey: "qa-modern-\(index)", payloadJSON: payload, createdAt: day, updatedAt: .now))
            }
            let habit: [String: Any] = ["question": "午饭后散步，是你的习惯吗？", "lead": "重复活动可能只是偶然，由你来判断。", "appName": "步行", "examples": [["sourceKey": note.id.uuidString, "title": "午后散步"]], "evidenceRefs": [note.id.uuidString], "proposedCategory": "散步", "dedupKey": "qa-modern-habit"]
            try db.saveSharedUserRecord(RiverSharedStateRecord(id: UUID(), kind: .habitCard, status: "shown", logicalKey: "qa-modern-habit", payloadJSON: String(decoding: try JSONSerialization.data(withJSONObject: habit), as: UTF8.self), createdAt: day, updatedAt: .now))
            if ProcessInfo.processInfo.arguments.contains("--riverdiary-qa-product-fixtures") {
                try seedProductAnalysis(db: db, day: day, evidence: note)
            }
            db.refreshTimeline(for: .now)
            node.objectWillChange.send()
            UserDefaults.standard.set(true, forKey: "river.qa.modern.seeded")
        } catch { assertionFailure("Isolated QA fixture failed: \(error)") }
    }
    private static func seedProductAnalysis(db: RiverLocalDatabase, day: Date, evidence: RiverEvent) throws {
        let first = try db.append(source: "qa-location", kind: "location.visit",
                                  payload: RiverEventPayload(latitude: 31.2304, longitude: 121.4737, horizontalAccuracy: 30),
                                  observedAt: day.addingTimeInterval(8 * 3600))
        _ = try db.append(source: "qa-location", kind: "location.visit",
                          payload: RiverEventPayload(latitude: 31.2360, longitude: 121.4850, horizontalAccuracy: 25),
                          observedAt: day.addingTimeInterval(14 * 3600))
        let frontier = try db.currentInputFrontier()
        let key = RiverIOSProjection.dayKey(day)
        let digest = RiverDayAnalysisDigest(dayKey: key, segments: [
            .init(candidateIDs: ["qa-place"], title: "上午的一次停留", summary: "记录到上午的位置线索。仅凭位置记录，不能判断停留期间的活动。",
                  evidenceRefs: ["event:\(first.id.uuidString)"], start: first.observedAt, end: first.observedAt),
            .init(candidateIDs: ["qa-note"], title: "整理想法，写下一段文字", summary: "手动记录提到坐在窗边整理想法，随后出现备忘录使用记录。",
                  evidenceRefs: ["event:\(evidence.id.uuidString)"], start: evidence.observedAt, end: evidence.observedAt)
        ])
        let text = "上午整理了想法并留下文字，同时记录到两段位置线索。应用和位置记录提供了活动依据，未记录的时段仍然未知。"
        for (kind, logicalKey, content) in [(RiverArtifactKind.dailyReview, RiverCanonicalArtifactKey.dailyReview(dayKey: key), Data(text.utf8)),
                                          (.semanticTimeline, "qa-product|d-" + key, try JSONEncoder().encode(digest))] {
            let stamp = try db.nextManifestStamp()
            let hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
            try db.insertArtifactRevision(RiverArtifactRevision(id: UUID().uuidString.lowercased(), logicalKey: logicalKey, kind: kind,
                revisionNumber: 1, originDeviceID: db.deviceID, clock: stamp.clock, inputFrontier: frontier,
                inputSnapshotHash: "isolated-qa-input", pipelineVersion: "qa", promptVersion: "3",
                modelProvider: "isolated-qa-fixture", modelIdentifier: "fixture", content: content, contentHash: hash,
                dependencies: [ArtifactDependency(type: "event", id: evidence.id.uuidString, rangeStart: day, rangeEnd: day.addingTimeInterval(86400))]))
        }
    }

}
#endif
