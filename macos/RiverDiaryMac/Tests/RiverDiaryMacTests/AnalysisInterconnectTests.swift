import XCTest
import RiverDiaryCore
@testable import RiverDiaryMac

private final class AnalysisRecoveryURLProtocol: URLProtocol {
    static let responseBody = Data(#"{"choices":[{"message":{"content":"**结论**\n已恢复的搜索结果。\n**相关日期**\n- 2026-09-28\n**证据**\n- 无\n**边界**\n相关不代表因果；如果你想，可以继续检索。"}}]}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - AI 分析数据互通测试
//
// 覆盖：结果层按去重键 upsert 与读取、上下文装配器（规则/记忆/结论/指纹/快照）、
// 日报结构化摘要解析、记忆候选解析、任务映射修正、恢复迁移、结论链与月信。

@MainActor
final class AnalysisInterconnectTests: XCTestCase {
    private func makeStore() throws -> V2Store {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-interconnect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return V2Store(databaseURL: directory.appendingPathComponent("interconnect.db"))
    }

    func testAnalysisRecoverySnapshotPreservesExactPromptAndTimelineValidationInputs() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = ActivitySession(
            appName: "Xcode", bundleID: "com.example.xcode", windowTitle: "RiverDiary.swift",
            category: "工作", start: start, end: start.addingTimeInterval(1_800)
        )
        let candidate = ActivityTimelineItem(
            id: "candidate-1", kind: .activity, start: session.start, end: session.end,
            sessions: [session]
        )
        let timelineContext = TimelineDigestRecoveryContext(
            dayKey: "2026-09-28", fingerprint: "fingerprint-v1", candidates: [candidate],
            captures: [], entries: [], browserVisits: [], locationEvents: []
        )
        let snapshot = PersistedAnalysisRequest(
            version: 1, taskRawValue: AITask.timelineDigest.rawValue,
            system: "exact system prompt",
            effectiveSystem: "exact system prompt",
            prompt: "exact user prompt with private diary evidence",
            temperature: 0.15, maxTokens: 2_000,
            archiveStartDate: "2026-09-28", archiveEndDate: "2026-09-28",
            sourceSummary: "daily timeline", evidenceIDs: [session.id], contextSnapshotID: UUID(),
            answerPolicy: .timelineDigest, includesStructuredDigest: false,
            allowedReferences: ["raw:\(session.id.uuidString)"],
            runMetadata: PersistedAnalysisRunMetadata(
                dedupKey: "timeline-digest|2026-09-28", rangeKey: "d-2026-09-28",
                evidenceRefs: ["raw:\(session.id.uuidString)"], digestJSON: nil
            ),
            timelineDigestContext: timelineContext,
            artifactInputFingerprint: "prompt-and-context-hash",
            providerLabel: "Ollama", modelIdentifier: "llama3.2", endpointFingerprint: "local-endpoint-hash"
        )

        let bytes = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(PersistedAnalysisRequest.self, from: bytes)
        XCTAssertEqual(restored.system, snapshot.system)
        XCTAssertEqual(restored.effectiveSystem, snapshot.effectiveSystem)
        XCTAssertEqual(restored.prompt, snapshot.prompt)
        XCTAssertEqual(restored.allowedReferences, snapshot.allowedReferences)
        XCTAssertEqual(restored.timelineDigestContext?.candidates, [candidate])
        XCTAssertEqual(restored.timelineDigestContext?.fingerprint, "fingerprint-v1")
        XCTAssertEqual(restored.endpointFingerprint, "local-endpoint-hash")

        let alternateProvider = PersistedAnalysisRequest(
            version: snapshot.version, taskRawValue: snapshot.taskRawValue, system: snapshot.system,
            effectiveSystem: snapshot.effectiveSystem, prompt: snapshot.prompt,
            temperature: snapshot.temperature, maxTokens: snapshot.maxTokens,
            archiveStartDate: snapshot.archiveStartDate, archiveEndDate: snapshot.archiveEndDate,
            sourceSummary: snapshot.sourceSummary, evidenceIDs: snapshot.evidenceIDs,
            contextSnapshotID: UUID(), answerPolicy: snapshot.answerPolicy,
            includesStructuredDigest: snapshot.includesStructuredDigest,
            allowedReferences: snapshot.allowedReferences, runMetadata: snapshot.runMetadata,
            timelineDigestContext: snapshot.timelineDigestContext,
            artifactInputFingerprint: snapshot.artifactInputFingerprint,
            providerLabel: "Different Provider", modelIdentifier: "other-model",
            endpointFingerprint: "other-endpoint"
        )
        func artifactInputHash(_ value: PersistedAnalysisRequest) -> String {
            analysisArtifactInputFingerprint(
                taskRawValue: value.taskRawValue, effectiveSystem: value.effectiveSystem,
                prompt: value.prompt, temperature: value.temperature, maxTokens: value.maxTokens,
                answerPolicy: value.answerPolicy, includesStructuredDigest: value.includesStructuredDigest
            )
        }
        XCTAssertEqual(artifactInputHash(snapshot), artifactInputHash(alternateProvider))
        XCTAssertNotEqual(analysisJobRequestFingerprint(snapshot), analysisJobRequestFingerprint(alternateProvider))
    }

    func testQueuedAnalysisJobReplaysSameFrontierAndCompletesItsArtifact() async throws {
        let v2 = try makeStore()
        let suiteName = "river-analysis-recovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalysisRecoveryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let ai = AIAssistantStore(v2Store: v2, userDefaults: defaults, urlSession: session)
        ai.provider = .ollama
        ai.endpoint = "http://localhost:11434/v1/chat/completions"
        ai.model = "llama3.2"
        XCTAssertTrue(ai.analysisReady)
        XCTAssertTrue(ai.canRunAutomaticAnalysis, "localhost inference does not require cloud consent")

        let device = try XCTUnwrap(v2.localDeviceIdentifier())
        let frontier = try v2.currentInputFrontier()
        let system = "Search local records accurately."
        let prompt = "Find the note about rebuilding River Diary."
        let sourceSummary = "search recovery test"
        let dedupKey = "memory-search|river-diary-rebuild"
        let rangeKey = "query:river-diary-rebuild"
        let endpointFingerprint = SHA256Hex.hash(Data(ai.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        let runMetadata = PersistedAnalysisRunMetadata(
            dedupKey: dedupKey, rangeKey: rangeKey, evidenceRefs: [], digestJSON: nil
        )
        let artifactInputFingerprint = analysisArtifactInputFingerprint(
            taskRawValue: AITask.memorySearch.rawValue, effectiveSystem: system, prompt: prompt,
            temperature: 0.1, maxTokens: 700, answerPolicy: .memorySearch,
            includesStructuredDigest: false
        )
        let snapshot = PersistedAnalysisRequest(
            version: 1, taskRawValue: AITask.memorySearch.rawValue, system: system,
            effectiveSystem: system, prompt: prompt, temperature: 0.1, maxTokens: 700,
            archiveStartDate: nil, archiveEndDate: nil, sourceSummary: sourceSummary,
            evidenceIDs: [], contextSnapshotID: nil, answerPolicy: .memorySearch,
            includesStructuredDigest: false, allowedReferences: [], runMetadata: runMetadata,
            timelineDigestContext: nil, artifactInputFingerprint: artifactInputFingerprint,
            providerLabel: ai.provider.label, modelIdentifier: ai.model, endpointFingerprint: endpointFingerprint
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshotData = try encoder.encode(snapshot)
        let requestFingerprint = analysisJobRequestFingerprint(snapshot)
        let pipeline = "1.0|\(ai.provider.label)|\(ai.model)|\(endpointFingerprint)"
        let jobID = RiverAnalysisJobScheduler.jobID(
            deviceID: device, logicalKey: dedupKey, artifactType: .insight,
            inputFrontier: frontier, pipelineVersion: pipeline, promptVersion: "1",
            requestFingerprint: requestFingerprint
        )
        let interruptedJob = RiverAnalysisJob(
            id: jobID, logicalKey: dedupKey, artifactType: .insight, inputFrontier: frontier,
            priority: 10, status: .running, attempt: 1, originDeviceID: device,
            pipelineVersion: pipeline, promptVersion: "1", requestSnapshot: snapshotData,
            requestFingerprint: requestFingerprint
        )
        XCTAssertTrue(v2.saveAnalysisJob(interruptedJob))

        await ai.resumeRecoverableAnalysisJobs()

        let finishedJob = try XCTUnwrap(v2.analysisJobs().first { $0.id == jobID })
        XCTAssertEqual(finishedJob.status, .succeeded)
        XCTAssertNil(finishedJob.requestSnapshot, "terminal jobs must not retain the full prompt")
        XCTAssertNotNil(v2.canonicalArtifactRevision(logicalKey: dedupKey, kind: .insight))
        XCTAssertTrue(ai.recoveredAnalysisStatus?.contains("成功 1 个") == true)

        let lateEvent = RawEvent(source: .manual, kind: .quickCapture, payload: RawEventPayload(text: "late evidence"))
        XCTAssertTrue(v2.insertRawEvent(lateEvent))
        let staleKey = dedupKey + "|stale-frontier"
        let staleJobID = RiverAnalysisJobScheduler.jobID(
            deviceID: device, logicalKey: staleKey, artifactType: .insight,
            inputFrontier: frontier, pipelineVersion: pipeline, promptVersion: "1",
            requestFingerprint: requestFingerprint
        )
        let staleJob = RiverAnalysisJob(
            id: staleJobID, logicalKey: staleKey, artifactType: .insight, inputFrontier: frontier,
            priority: 10, status: .running, attempt: 1, originDeviceID: device,
            pipelineVersion: pipeline, promptVersion: "1", requestSnapshot: snapshotData,
            requestFingerprint: requestFingerprint
        )
        XCTAssertTrue(v2.saveAnalysisJob(staleJob))
        await ai.resumeRecoverableAnalysisJobs()
        XCTAssertEqual(v2.analysisJobs().first { $0.id == staleJobID }?.status, .superseded)
        XCTAssertEqual(v2.analysisRuns().count, 1, "stale-frontier snapshot must not be sent")
    }

    func testTimelineDigestClarificationBecomesSharedAndAnnotationClosesIt() throws {
        let v2 = try makeStore()
        let ai = AIAssistantStore(v2Store: v2)
        let device = try XCTUnwrap(v2.localDeviceIdentifier())
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
        let candidateID = "activity-\(sessionID.uuidString)-\(date.timeIntervalSince1970)"
        let annotationKey = "1700000000|com.example.editor|Editor"
        XCTAssertTrue(v2.insertRawEvent(RawEvent(
            id: sessionID, timestamp: date, source: .systemApp, kind: .appForeground,
            payload: RawEventPayload(appName: "Editor", bundleID: "com.example.editor", sessionEnd: date.addingTimeInterval(1_800))
        )))
        let clarification = TimelineDigestClarification(
            candidateID: candidateID,
            annotationKey: nil,
            observation: "这段时间主要使用了编辑器。",
            opening: "当时在编辑什么内容？",
            evidenceRefs: ["raw:source-1"]
        )
        let digest = TimelineDigest(
            dayKey: "2026-09-28", sourceFingerprint: "timeline-source-v1",
            overview: "当天有一段工作活动。", overviewCandidateIDs: [clarification.candidateID],
            overviewCaptureIDs: [], overviewDiaryDates: [],
            segments: [TimelineDigestSegment(
                candidateIDs: [clarification.candidateID], title: "编辑项目", summary: "使用编辑器处理项目内容。",
                evidenceRefs: clarification.evidenceRefs, start: date, end: date.addingTimeInterval(1_800)
            )],
            clarifications: [clarification]
        )
        let content = Data(try XCTUnwrap(digest.encodedJSON).utf8)
        let artifact = RiverArtifactRevision(
            id: "timeline-digest-recovery-test", logicalKey: "timelineDigest|d-2026-09-28",
            kind: .semanticTimeline, revisionNumber: 1, originDeviceID: device,
            clock: HybridLogicalClock(physicalMilliseconds: 1_700_000_000_000, deviceID: device),
            inputFrontier: try v2.currentInputFrontier(), inputSnapshotHash: "timeline-source-v1",
            pipelineVersion: "1.0", promptVersion: "1", modelProvider: "test", modelIdentifier: "test-model",
            content: content, contentHash: SHA256Hex.hash(content), status: .current
        )
        XCTAssertTrue(v2.insertArtifactRevision(artifact))
        XCTAssertEqual(ai.reconcilePendingTimelineConfirmations(), 1)
        let pending = try XCTUnwrap(v2.sharedUserRecords().first { $0.kind == .pendingConfirmation })
        XCTAssertEqual(pending.status, "pending")
        XCTAssertEqual(pending.pendingConfirmationContent?.targetID, annotationKey)
        XCTAssertEqual(pending.pendingConfirmationContent?.evidenceRefs, ["raw:source-1"])

        let annotation = TimelineAnnotation(title: "编写同步逻辑", note: "用户补充了具体任务", isReviewed: true, reviewedAt: date, updatedAt: date)
        XCTAssertNotNil(v2.appendStateOperation(
            targetID: annotationKey, fieldKey: "annotation", operationType: "timeline.annotation.set",
            payload: try JSONEncoder().encode(annotation)
        ))
        XCTAssertEqual(ai.reconcilePendingTimelineConfirmations(), 1)
        XCTAssertEqual(v2.sharedUserRecords().first { $0.id == pending.id }?.status, "corrected")
    }

    // MARK: B1 结果层

    func testKeyedUpsertKeepsOnlyLatestPerDedupKey() throws {
        let v2 = try makeStore()
        let run1 = AnalysisRun(task: .dailyOverview, outputText: "第一版", model: "m")
        XCTAssertTrue(v2.upsertAnalysisRun(run1, dedupKey: "dailyOverview|d-2026-09-20", rangeKey: "d-2026-09-20", evidenceRefs: ["diary:2026-09-20"], digestJSON: nil))
        let run2 = AnalysisRun(task: .dailyOverview, outputText: "第二版", model: "m")
        XCTAssertTrue(v2.upsertAnalysisRun(run2, dedupKey: "dailyOverview|d-2026-09-20", rangeKey: "d-2026-09-20", evidenceRefs: ["diary:2026-09-20"], digestJSON: "{\"headline\":\"第二版\"}"))

        let latest = try XCTUnwrap(v2.latestAnalysisRun(dedupKey: "dailyOverview|d-2026-09-20"))
        XCTAssertEqual(latest.run.outputText, "第二版")
        XCTAssertEqual(latest.evidenceRefs, ["diary:2026-09-20"])
        XCTAssertEqual(latest.digestJSON, "{\"headline\":\"第二版\"}")
        XCTAssertEqual(latest.rangeKey, "d-2026-09-20")
        // 同键只剩一行：结果层不随重复触发无限膨胀。
        XCTAssertEqual(v2.countRows(in: .analysisRuns), 1)

        // 另一个键互不影响。
        XCTAssertTrue(v2.upsertAnalysisRun(AnalysisRun(task: .dailyOverview, outputText: "另一天"), dedupKey: "dailyOverview|d-2026-09-21", rangeKey: "d-2026-09-21", evidenceRefs: []))
        XCTAssertEqual(v2.countRows(in: .analysisRuns), 2)
    }

    func testLegacyRowsWithoutKeysRemainReadable() throws {
        let v2 = try makeStore()
        XCTAssertTrue(v2.insertAnalysisRun(AnalysisRun(task: .dailyOverview, outputText: "旧格式结果")))
        let runs = v2.analysisRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.outputText, "旧格式结果")
        XCTAssertNil(v2.latestAnalysisRun(dedupKey: "anything"))
    }

    func testAnalysisRunRecordsFilterByTaskAndTime() throws {
        let v2 = try makeStore()
        let now = Date()
        let early = AnalysisRun(task: .dailyOverview, outputText: "周一", createdAt: now.addingTimeInterval(-3 * 86_400))
        let late = AnalysisRun(task: .dailyOverview, outputText: "今天", createdAt: now)
        XCTAssertTrue(v2.insertAnalysisRun(early, evidenceRefs: [], digestJSON: nil))
        XCTAssertTrue(v2.insertAnalysisRun(late, evidenceRefs: [], digestJSON: nil))
        XCTAssertTrue(v2.insertAnalysisRun(AnalysisRun(task: .weeklyReview, outputText: "周报"), evidenceRefs: [], digestJSON: nil))

        let records = v2.analysisRunRecords(task: .dailyOverview, between: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(60))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.run.outputText, "今天")
    }

    // MARK: A 上下文装配器

    func testAssemblerIncludesOnlyActiveUserConfirmedRules() throws {
        let v2 = try makeStore()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        func row(_ rule: HabitPersonalRule) throws -> String {
            String(data: try encoder.encode(rule), encoding: .utf8)!
        }
        let active = HabitPersonalRule(
            dedupKey: "pattern:codex", conditionBundleID: "com.openai.codex", conditionAppName: "Codex",
            conditionPlaceKey: "宿舍", conclusionCategory: "工作", scopeText: "Codex · 宿舍附近",
            status: .active, origin: .userConfirmed, recordedAt: Date(), validFrom: Date()
        )
        let retired = HabitPersonalRule(
            dedupKey: "pattern:chrome", conditionBundleID: "com.google.Chrome", conditionAppName: "Chrome",
            conditionPlaceKey: nil, conclusionCategory: "娱乐", scopeText: "Chrome",
            status: .retired, origin: .userConfirmed, recordedAt: Date(), validFrom: Date()
        )
        let autoObserved = HabitPersonalRule(
            dedupKey: "pattern:notes", conditionBundleID: "com.apple.Notes", conditionAppName: "备忘录",
            conditionPlaceKey: nil, conclusionCategory: "学习", scopeText: "备忘录",
            status: .active, origin: .autoObserved, recordedAt: Date(), validFrom: Date()
        )
        XCTAssertTrue(v2.upsertHabitRule(id: active.id, status: active.status.rawValue, payloadJSON: try row(active), updatedAt: Date()))
        XCTAssertTrue(v2.upsertHabitRule(id: retired.id, status: retired.status.rawValue, payloadJSON: try row(retired), updatedAt: Date()))
        XCTAssertTrue(v2.upsertHabitRule(id: autoObserved.id, status: autoObserved.status.rawValue, payloadJSON: try row(autoObserved), updatedAt: Date()))

        let lines = ContextAssembler.activeRuleLines(v2Store: v2)
        XCTAssertEqual(lines.count, 1, "退役规则与自主观察候选都不进 prompt")
        XCTAssertTrue(lines[0].contains("Codex · 宿舍附近"))
        XCTAssertTrue(lines[0].contains("工作"))
    }

    func testAssemblePersistsSnapshotAndFingerprintReactstoRuleChanges() throws {
        let v2 = try makeStore()
        let day = ContextAssembler.dayFacts(
            dayKey: "2026-09-20",
            entries: [],
            captures: [],
            sessions: [makeSession("com.openai.codex", "Codex", "2026-09-20", 10, 84)]
        )
        let first = ContextAssembler.assemble(
            v2Store: v2, task: .analysisDaily, startDate: "2026-09-20", endDate: "2026-09-20",
            days: [day], evidenceRefs: ["diary:2026-09-20"], conclusions: [], model: "m"
        )
        XCTAssertNotNil(first.snapshotID, "上下文应持久化到 context_snapshots")
        XCTAssertFalse(first.fingerprint.isEmpty)

        // 快照可回读：AnalysisRun.inputContextReference 指向的内容能解开。
        let snapshot = try XCTUnwrap(v2.contextSnapshot(id: first.snapshotID!))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let context = try decoder.decode(AnalysisContext.self, from: Data(snapshot.payloadJSON.utf8))
        XCTAssertEqual(context.personalRules, [])
        XCTAssertEqual(context.days.first?.recordedMinutes, 84)

        // 新增一条用户规则 → 指纹变化（缓存正确失效）。
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let rule = HabitPersonalRule(
            dedupKey: "pattern:codex", conditionBundleID: "com.openai.codex", conditionAppName: "Codex",
            conditionPlaceKey: nil, conclusionCategory: "工作", scopeText: "Codex",
            status: .active, origin: .userConfirmed, recordedAt: Date(), validFrom: Date()
        )
        XCTAssertTrue(v2.upsertHabitRule(id: rule.id, status: rule.status.rawValue, payloadJSON: String(data: try encoder.encode(rule), encoding: .utf8)!, updatedAt: Date()))
        let second = ContextAssembler.assemble(
            v2Store: v2, task: .analysisDaily, startDate: "2026-09-20", endDate: "2026-09-20",
            days: [day], evidenceRefs: ["diary:2026-09-20"], conclusions: [], model: "m"
        )
        XCTAssertNotEqual(second.fingerprint, first.fingerprint)
        XCTAssertTrue(second.ruleLines.contains("Codex"))

        // 相同输入重复装配：指纹稳定（可作缓存键）。
        let third = ContextAssembler.assemble(
            v2Store: v2, task: .analysisDaily, startDate: "2026-09-20", endDate: "2026-09-20",
            days: [day], evidenceRefs: ["diary:2026-09-20"], conclusions: [], model: "m"
        )
        XCTAssertEqual(third.fingerprint, second.fingerprint)
    }

    func testConfirmedMemoryLinesOnlyIncludeConfirmed() throws {
        let v2 = try makeStore()
        let confirmed = Memory(title: "河流日记是长期项目", body: "持续开发中", kind: .projectTrajectory)
        let unconfirmed = Memory(title: "未经确认的记忆", body: "模型猜的", kind: .other)
        XCTAssertTrue(v2.insertMemory(confirmed))
        XCTAssertTrue(v2.insertMemory(unconfirmed))
        XCTAssertTrue(v2.setMemoryConfirmation(confirmed.id, confirmed: true, note: ""))

        let lines = ContextAssembler.confirmedMemoryLines(v2Store: v2)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("河流日记是长期项目"))
    }

    func testConclusionSummariesPreferDigestHeadline() throws {
        let v2 = try makeStore()
        let digestJSON = "{\"headline\":\"9/20 全天专注开发\",\"points\":[]}"
        XCTAssertTrue(v2.upsertAnalysisRun(
            AnalysisRun(task: .dailyOverview, outputText: "**结论**\n一大段正文……", createdAt: Date()),
            dedupKey: "dailyOverview|d-2026-09-20", rangeKey: "d-2026-09-20",
            evidenceRefs: [], digestJSON: digestJSON
        ))
        let summaries = ContextAssembler.conclusionSummaries(
            v2Store: v2, task: .dailyOverview,
            between: Date().addingTimeInterval(-86_400), end: Date().addingTimeInterval(60)
        )
        XCTAssertEqual(summaries.first?.headline, "9/20 全天专注开发")
    }

    // MARK: B2 日报摘要解析

    func testDigestExtractionStripsCommentAndClamps() {
        let answer = """
        **结论**
        今天主要在做时间线整理。

        <!-- digest: {"headline":"9/20 全天专注开发","points":["上午写引擎","晚上测试","多余的一条","再多的一条"]} -->
        """
        let (digest, clean) = AnalysisDigestParser.extract(from: answer)
        XCTAssertEqual(digest.headline, "9/20 全天专注开发")
        XCTAssertEqual(digest.points.count, 3, "要点最多保留 3 条")
        XCTAssertFalse(clean.contains("digest:"), "可见答案不再包含摘要注释")
        XCTAssertTrue(clean.contains("今天主要在做时间线整理"))

        // displayText 也剥 digest 注释（今日页/复盘页都走这条路径）。
        XCTAssertFalse(EvidenceReference.displayText(from: answer).contains("digest:"))
    }

    func testDigestFallbackUsesFirstMeaningfulLine() {
        let answer = "**结论**\n今天的记录较少。\n<!-- digest: 不是JSON -->"
        let digest = AnalysisDigestParser.fallbackHeadline(ofOutput: answer)
        XCTAssertEqual(digest, "今天的记录较少。")
        // 注释非法时不从正文剥离（保持答案完整）——extract 走回退。
        let (parsed, clean) = AnalysisDigestParser.extract(from: answer)
        XCTAssertEqual(parsed.headline, "今天的记录较少。")
        XCTAssertTrue(clean.contains("**结论**"))
    }

    // MARK: C3 记忆候选解析

    func testMemoryCandidateParserValidatesKindsAndEvidence() {
        let raw = """
        {"candidates":[
            {"title":"河流日记是长期项目","body":"近两周持续开发","kind":"projectTrajectory","evidence":["diary:2026-09-20","capture:11111111-1111-1111-1111-111111111111"]},
            {"title":"编造的类型","body":"x","kind":"other","evidence":[]},
            {"title":"太","body":"短标题", "kind":"habit","evidence":[]},
            {"title":"夜间开发习惯","body":"晚上常写代码","kind":"habit","evidence":["diary:2099-99-99"]}
        ]}
        """
        let allowed = EvidenceReference.allowedSet(diaryDays: ["2026-09-20"], captureIDs: [UUID(uuidString: "11111111-1111-1111-1111-111111111111")!])
        let candidates = MemoryCandidateParser.parse(raw, allowedRefs: allowed)
        XCTAssertEqual(candidates.count, 2, "other 类型与非法 evidence 的候选被过滤")
        XCTAssertEqual(candidates[0].kind, .projectTrajectory)
        XCTAssertEqual(candidates[0].evidenceRefs, ["diary:2026-09-20", "capture:11111111-1111-1111-1111-111111111111"], "白名单内的 diary 与 capture 引用都保留")
        XCTAssertEqual(candidates[1].kind, .habit)
        XCTAssertTrue(candidates[1].evidenceRefs.isEmpty, "非法日期引用丢弃后允许为空")
    }

    func testMemoryCandidateParserRejectsGarbage() {
        XCTAssertTrue(MemoryCandidateParser.parse("这不是 JSON", allowedRefs: []).isEmpty)
        XCTAssertTrue(MemoryCandidateParser.parse("{\"candidates\":[]}", allowedRefs: []).isEmpty)
    }

    // MARK: 映射修正 + 恢复迁移（D2）

    func testRiverTaskKindMappingIsNoLongerLossy() {
        let store = AIAssistantStore(v2Store: try! makeStore())
        XCTAssertEqual(store.riverTaskKind(for: .analysisDaily), .dailyOverview)
        XCTAssertEqual(store.riverTaskKind(for: .analysisWeekly), .weeklyReview)
        XCTAssertEqual(store.riverTaskKind(for: .timelineDigest), .timelineDigest)
        XCTAssertEqual(store.riverTaskKind(for: .memorySearch), .memorySearch)
    }

    func testRestorePrefersV2ResultLayer() throws {
        let v2 = try makeStore()
        let store = AIAssistantStore(v2Store: v2)
        let dayKey = "2026-09-20"
        XCTAssertTrue(v2.upsertAnalysisRun(
            AnalysisRun(task: .dailyOverview, outputText: "**结论**\nV2 日报", model: "m"),
            dedupKey: "dailyOverview|\(ContextAssembler.dayRangeKey(dayKey))",
            rangeKey: ContextAssembler.dayRangeKey(dayKey),
            evidenceRefs: ["diary:2026-09-20"],
            digestJSON: "{\"headline\":\"V2 日报\",\"points\":[]}"
        ))
        let digestJSON = "{\"schemaVersion\":1,\"dayKey\":\"\(dayKey)\",\"sourceFingerprint\":\"abc\",\"overview\":\"概览\",\"overviewCandidateIDs\":[],\"overviewCaptureIDs\":[],\"overviewDiaryDates\":[],\"segments\":[]}"
        XCTAssertTrue(v2.upsertAnalysisRun(
            AnalysisRun(task: .timelineDigest, outputText: digestJSON, model: "m"),
            dedupKey: "timelineDigest|\(ContextAssembler.dayRangeKey(dayKey))",
            rangeKey: ContextAssembler.dayRangeKey(dayKey),
            evidenceRefs: [],
            digestJSON: nil
        ))

        store.restoreAnalysisResults(startDate: dayKey, endDate: dayKey)
        XCTAssertEqual(store.state(for: .analysisDaily)?.answer, "**结论**\nV2 日报")
        XCTAssertEqual(store.state(for: .analysisDaily)?.isArchived, true)
        XCTAssertEqual(store.timelineDigest(for: dayKey)?.dayKey, dayKey, "digest JSON 从结果层恢复")
    }

    func testStoredEvidenceRefsReadFromResultLayer() throws {
        let v2 = try makeStore()
        let store = AIAssistantStore(v2Store: v2)
        XCTAssertTrue(v2.upsertAnalysisRun(
            AnalysisRun(task: .weeklyReview, outputText: "**结论**\n周报", model: "m"),
            dedupKey: "weeklyReview|w-2026-09-21",
            rangeKey: "w-2026-09-21",
            evidenceRefs: ["diary:2026-09-21", "raw:22222222-2222-2222-2222-222222222222"]
        ))
        let refs = store.storedEvidenceRefs(for: .analysisWeekly, startDate: "2026-09-21", endDate: "2026-09-27")
        XCTAssertEqual(refs, ["diary:2026-09-21", "raw:22222222-2222-2222-2222-222222222222"])
    }

    // MARK: B3 结论检索

    func testConclusionSearchMatchesQueryBigrams() throws {
        let v2 = try makeStore()
        let now = Date()
        XCTAssertTrue(v2.upsertAnalysisRun(
            AnalysisRun(task: .dailyOverview, outputText: "**结论**\n今天在准备英语四级考试。", createdAt: now.addingTimeInterval(-3_600)),
            dedupKey: "dailyOverview|d-old", rangeKey: "d-old", evidenceRefs: []
        ))
        XCTAssertTrue(v2.upsertAnalysisRun(
            AnalysisRun(task: .dailyOverview, outputText: "**结论**\n今天在整理时间线。", createdAt: now),
            dedupKey: "dailyOverview|d-new", rangeKey: "d-new", evidenceRefs: []
        ))

        let matched = AIConclusionSearch.notes(matching: "四级考试进度", v2Store: v2, now: now)
        XCTAssertEqual(matched.count, 1)
        XCTAssertTrue(matched[0].headline.contains("英语四级"))

        XCTAssertTrue(AIConclusionSearch.notes(matching: "完全无关的查询词", v2Store: v2, now: now).isEmpty)
        XCTAssertTrue(AIConclusionSearch.notes(matching: "四", v2Store: v2, now: now).isEmpty, "单字查询不触发检索")
    }

    // MARK: B2 月信引用周报

    func testMonthlyLetterCarriesWeeklySummary() throws {
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15))!
        let entry = DiaryEntry(
            pageID: "2026-09-15", date: "2026-09-15", score: 80, daily: nil,
            overview: "平稳的一天", thoughts: [], memos: [], tags: [], category: "工作",
            metrics: nil, stage: nil, screenHours: nil, views: nil, screenApps: [], browseSites: [],
            screenNote: nil, browseNote: nil, didItems: [], health: nil
        )
        let letter = try XCTUnwrap(MonthlyLetter.make(
            for: date,
            entries: [entry],
            captures: [:],
            sessions: [],
            now: date,
            calendar: calendar,
            aiWeeklySummary: "本周开发节奏稳定，午后是专注高峰"
        ))
        XCTAssertTrue(letter.body.contains("AI 周读的一个观察"))
        XCTAssertTrue(letter.body.contains("午后是专注高峰"))

        // 不传摘要时信件保持原样（回退兼容）。
        let plain = try XCTUnwrap(MonthlyLetter.make(
            for: date, entries: [entry], captures: [:], sessions: [], now: date, calendar: calendar
        ))
        XCTAssertFalse(plain.body.contains("AI 周读"))
    }

    // MARK: Helpers

    private func makeSession(_ bundleID: String, _ appName: String, _ dayKey: String, _ hour: Int, _ minutes: Int) -> ActivitySession {
        let day = DiaryEntry.dateFormatter.date(from: dayKey)!
        let start = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        return ActivitySession(
            appName: appName,
            bundleID: bundleID,
            windowTitle: nil,
            category: ActivityClassifier.category(appName: appName, title: nil),
            start: start,
            end: start.addingTimeInterval(TimeInterval(minutes * 60))
        )
    }
}
