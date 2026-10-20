import CryptoKit
import Combine
import Foundation
import RiverDiaryCore
import SwiftUI

@MainActor
final class IPhoneAIStore: ObservableObject {
    @Published var endpoint: String {
        didSet {
            UserDefaults.standard.set(endpoint, forKey: "river.ai.endpoint")
            scheduleAutomaticDailyReview(configurationChanged: true)
        }
    }
    @Published var model: String {
        didSet {
            UserDefaults.standard.set(model, forKey: "river.ai.model")
            scheduleAutomaticDailyReview(configurationChanged: true)
        }
    }
    @Published var includePlaces: Bool {
        didSet {
            UserDefaults.standard.set(includePlaces, forKey: "river.ai.includePlaces")
            scheduleAutomaticDailyReview(configurationChanged: true)
        }
    }
    @Published var includeHealth: Bool {
        didSet {
            UserDefaults.standard.set(includeHealth, forKey: "river.ai.includeHealth")
            scheduleAutomaticDailyReview(configurationChanged: true)
        }
    }
    @Published var includeManualText: Bool {
        didSet {
            UserDefaults.standard.set(includeManualText, forKey: "river.ai.includeManualText")
            scheduleAutomaticDailyReview(configurationChanged: true)
        }
    }
    @Published var includeSharedMemories: Bool {
        didSet {
            UserDefaults.standard.set(includeSharedMemories, forKey: "river.ai.includeSharedMemories")
            scheduleAutomaticDailyReview(configurationChanged: true)
        }
    }
    @Published var includePhotoObservations: Bool {
        didSet {
            UserDefaults.standard.set(includePhotoObservations, forKey: "river.ai.includePhotoObservations")
            scheduleAutomaticDailyReview(configurationChanged: true)
        }
    }
    @Published var allowsPhotoAI: Bool {
        didSet {
            UserDefaults.standard.set(allowsPhotoAI, forKey: "river.ai.photoConsent")
            scheduleAutomaticDailyReview(configurationChanged: true)
        }
    }
    @Published var allowsNetworkAnalysis: Bool {
        didSet {
            UserDefaults.standard.set(allowsNetworkAnalysis, forKey: "river.ai.networkConsent")
            if allowsNetworkAnalysis {
                resumeQueuedDailyReviewIfNeeded()
                scheduleAutomaticDailyReview(configurationChanged: true)
            } else {
                automaticAnalysisTask?.cancel()
            }
        }
    }
    @Published var apiKeyInput = ""
    @Published private(set) var hasAPIKey = RiverSecureStore.hasNetworkAIKey()
    @Published private(set) var isGenerating = false
    @Published private(set) var status = "尚未分析"
    @Published private(set) var errorMessage: String?
    @Published private(set) var dailyReview: String?

    private let database: RiverLocalDatabase
    private let photoAnalyzer: IPhonePhotoAnalyzer?
    private let session: URLSession
    private var databaseRevisionObserver: AnyCancellable?
    private var automaticAnalysisTask: Task<Void, Never>?
    private var lastObservedFrontier: InputFrontier?
    private var lastAutomaticAttemptKey = UserDefaults.standard.string(forKey: "river.ai.lastAutomaticAttemptKey")
    private let pipelineVersion = "1.0"
    private let promptVersion = "3"

    init(database: RiverLocalDatabase, photoAnalyzer: IPhonePhotoAnalyzer? = nil, session: URLSession = .shared) {
        self.database = database
        self.photoAnalyzer = photoAnalyzer
        self.session = session
        let savedEndpoint = UserDefaults.standard.string(forKey: "river.ai.endpoint") ?? "https://api.deepseek.com/chat/completions"
        let savedModel = UserDefaults.standard.string(forKey: "river.ai.model") ?? "deepseek-flash"
        let isDeepSeekEndpoint = URLComponents(string: savedEndpoint)?.host?.lowercased() == "api.deepseek.com"
        let initialModel = isDeepSeekEndpoint && ["deepseek-chat", "deepseek-reasoner"].contains(savedModel.lowercased())
            ? "deepseek-flash" : savedModel
        endpoint = savedEndpoint
        model = initialModel
        if initialModel != savedModel { UserDefaults.standard.set(initialModel, forKey: "river.ai.model") }
        includePlaces = UserDefaults.standard.bool(forKey: "river.ai.includePlaces")
        includeHealth = UserDefaults.standard.bool(forKey: "river.ai.includeHealth")
        includeManualText = UserDefaults.standard.bool(forKey: "river.ai.includeManualText")
        includeSharedMemories = UserDefaults.standard.bool(forKey: "river.ai.includeSharedMemories")
        includePhotoObservations = UserDefaults.standard.bool(forKey: "river.ai.includePhotoObservations")
        allowsPhotoAI = UserDefaults.standard.bool(forKey: "river.ai.photoConsent")
        allowsNetworkAnalysis = UserDefaults.standard.bool(forKey: "river.ai.networkConsent")
        lastObservedFrontier = try? database.currentInputFrontier()
        databaseRevisionObserver = database.$dataRevision.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reloadDailyReview()
                self.resumeQueuedDailyReviewIfNeeded()
                if self.inputFrontierChanged() {
                    self.scheduleAutomaticDailyReview()
                }
            }
        }
        reloadDailyReview()
        resumeQueuedDailyReviewIfNeeded()
        scheduleAutomaticDailyReview()
    }

    var usesLocalEndpoint: Bool {
        guard let host = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    var canAskRiver: Bool { usesLocalEndpoint || (allowsNetworkAnalysis && hasAPIKey) }
    var canUsePhotoAI: Bool {
        photoAnalyzer?.isEnabled == true && (usesLocalEndpoint || (allowsNetworkAnalysis && hasAPIKey))
    }

    /// Inspects saved fields only; never makes a request or verifies provider credentials.
    func configurationIssue() -> String? {
        guard let url = Self.normalizedChatCompletionsURL(from: endpoint) else { return "请输入有效的 API 基础地址或完整接口地址。" }
        let local = ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        guard url.scheme?.lowercased() == "https" || (local && url.scheme?.lowercased() == "http") else { return "网络服务请使用 HTTPS；只有本机模型可以使用 HTTP。" }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "请填写模型名称。" }
        guard local || hasAPIKey else { return "尚未保存 API Key。填写后保存到本机钥匙串。" }
        return nil
    }

    func saveAPIKey() {
        guard !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try RiverSecureStore.saveNetworkAIKey(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines))
            hasAPIKey = true
            apiKeyInput = ""
            errorMessage = nil
            if allowsNetworkAnalysis { scheduleAutomaticDailyReview(configurationChanged: true) }
        } catch {
            errorMessage = "API 密钥无法保存在钥匙串：\(error.localizedDescription)"
        }
    }

    func removeAPIKey() {
        do {
            try RiverSecureStore.deleteNetworkAIKey()
            hasAPIKey = false
            apiKeyInput = ""
            automaticAnalysisTask?.cancel()
            errorMessage = nil
            status = "网络 AI 密钥已移除"
        } catch {
            errorMessage = "网络 AI 密钥无法从钥匙串移除：\(error.localizedDescription)"
        }
    }

    func analyzeToday(automaticRecomputeDepth: Int = 0, automaticTrigger: Bool = false, analysisDate: Date? = nil) async {
        guard !isGenerating else { return }
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestURL = Self.normalizedChatCompletionsURL(from: normalizedEndpoint) else {
            errorMessage = "请输入有效的 OpenAI 兼容 API 基础地址或 Chat Completions 完整地址。"
            status = "配置无效"
            return
        }
        let localHost = ["localhost", "127.0.0.1", "::1"].contains(requestURL.host?.lowercased() ?? "")
        guard requestURL.scheme?.lowercased() == "https" || (localHost && requestURL.scheme?.lowercased() == "http") else {
            errorMessage = "网络 AI 必须使用 HTTPS；只有本机 Ollama / LM Studio 可以使用 HTTP。"
            status = "配置无效"
            return
        }
        guard localHost || allowsNetworkAnalysis else {
            errorMessage = "尚未同意向网络 AI 发送个人数据。请在设置中明确开启授权。"
            status = "等待网络 AI 授权"
            return
        }
        let requestModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestModel.isEmpty else {
            errorMessage = "请先填写模型名称。"
            status = "配置无效"
            return
        }

        isGenerating = true
        defer { isGenerating = false }
        var photoAnalysisWarning: String?
        var activeJob: RiverAnalysisJob?
        do {
            let apiKey = localHost ? nil : try RiverSecureStore.loadNetworkAIKey()
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: analysisDate ?? Date())
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            if allowsPhotoAI, localHost || (allowsNetworkAnalysis && hasAPIKey), let photoAnalyzer {
                let photoInputs = await photoAnalyzer.recentAIInputs(from: start, to: end, limit: 4)
                do {
                    try await analyzePhotoGroups(photoInputs, start: start, end: end,
                                                 endpoint: requestURL, model: requestModel, apiKey: apiKey)
                } catch {
                    photoAnalysisWarning = "照片模型暂不可用；本机位置与场景线索仍会保留。"
                }
            }
            let events = try database.events(from: start, to: end)
            let dayKey = Self.dayKey(start)

            let selected = events.compactMap { event -> (RiverEvent, RiverEventPayload)? in
                guard let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload) else { return nil }
                if event.kind.hasPrefix("location.") && !includePlaces { return nil }
                if event.kind.hasPrefix("health.") && !includeHealth { return nil }
                if (event.kind == "media.photoObservation" || payload.mediaSummary != nil)
                    && !includePhotoObservations && !allowsPhotoAI { return nil }
                if payload.text != nil && !includeManualText { return nil }
                return (event, payload)
            }
            let selectedJournals = includeManualText
                ? database.sharedUserRecords.filter { $0.kind == .journalEntry && $0.status == "current" && $0.logicalKey == dayKey }
                    .compactMap(\.journalEntryContent)
                    .filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                : []
            let lines = selected.map { event, payload in "[event_id: \(event.id.uuidString)] " + Self.promptLine(event, payload) }
                + selectedJournals.map { "\(dayKey) · 用户手写日记：\($0.body.prefix(1_000))" }
            guard !lines.isEmpty else {
                status = events.isEmpty ? "等待真实事件" : "没有所选范围内的分析资料"
                errorMessage = events.isEmpty
                    ? "今天还没有可分析的事件或手写日记。"
                    : "当前隐私选项筛掉了今天的全部事件和手写日记。"
                return
            }

            // Capture the frontier before awaiting the provider so events that
            // arrive during the request are not claimed as model input.
            let frontier = try database.currentInputFrontier()
            let logicalKey = RiverCanonicalArtifactKey.dailyReview(dayKey: dayKey)
            let provider = localHost ? "local-openai-compatible" : "network-openai-compatible"
            let system = "你是 River Diary 的个人生活整理助手。只根据给出的时间线和照片证据写简洁日终回顾；分清观察、推断和未知，不补造行为，不复述坐标。照片不等于用户吃过或到访过。出行方式只按运动传感器线索命名，汽车线索不可写成打车。若对食物照片估算热量，只给宽范围并明确标注‘照片估算、份量不确定’；证据不足就写未知，不能给精确数值或医疗建议。只返回 JSON：{\"overview\":\"这一天主要做了什么，简短中文概览\",\"moments\":[{\"title\":\"活动片段标题\",\"summary\":\"依据支持的活动内容，最多220字\",\"event_ids\":[\"资料中的真实事件ID\"]}]}。最多6个片段，每段summary最多120字，事件ID不能编造、不能跨片段重复；缺少活动细节时只写应用使用，不宣称已完成任务。手写日记可用于概览，不要为它编造事件ID。"
            let user = "请把所选日期的主要活动整理成清楚的生活片段，优先合并同一段外出中的位置、照片、步行和停留，指出有依据的活动、步数与出行方式，并简要说明真正不确定的地方。\n\n资料：\n" + lines.joined(separator: "\n")
            let requestBody = ChatCompletionRequest(
                model: requestModel,
                messages: [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: user)],
                temperature: 0.2,
                max_tokens: 2000
            )
            let artifactInputFingerprint = RiverAnalysisFingerprints.artifactInput(
                frontier: frontier, systemPrompt: system, userPrompt: user
            )
            let endpointFingerprint = Self.sha256(Data(requestURL.absoluteString.utf8))
            let jobPipeline = "\(pipelineVersion)|\(provider)|\(requestModel)|\(endpointFingerprint)"
            let requestFingerprint = RiverAnalysisFingerprints.request(
                endpoint: requestURL.absoluteString, model: requestModel,
                systemPrompt: system, userPrompt: user, temperature: requestBody.temperature,
                maxTokens: requestBody.max_tokens
            )

            for job in try database.analysisJobs()
            where job.logicalKey == logicalKey
                && (job.status == .queued || job.status == .running)
                && (job.inputFrontier != frontier || job.pipelineVersion != jobPipeline
                    || job.requestFingerprint != requestFingerprint) {
                guard try database.saveAnalysisJob(job.transitioning(
                    to: .superseded, error: "当前输入或请求设置已变化；旧请求不会重放。"
                )) else {
                    throw RiverLocalDatabaseError.sql("旧 AnalysisJob 无法安全终止。")
                }
            }

            // Canonical reuse is cross-device: the receiver trusts an Artifact
            // with the same frontier and pipeline/prompt versions even when
            // its local prompt serialization differs from the origin node.
            if let existing = try database.canonicalArtifactRevisions().first(where: {
                $0.logicalKey == logicalKey && $0.kind == .dailyReview
                    && $0.inputFrontier == frontier && $0.pipelineVersion == pipelineVersion
                    && $0.promptVersion == promptVersion && $0.status != .stale
            }) {
                if let queued = try database.analysisJobs().first(where: {
                    $0.logicalKey == logicalKey && $0.inputFrontier == frontier
                        && $0.pipelineVersion == jobPipeline && $0.requestFingerprint == requestFingerprint
                        && ($0.status == .queued || $0.status == .running)
                }) {
                    guard try database.saveAnalysisJob(queued.transitioning(to: .succeeded)) else {
                        throw RiverLocalDatabaseError.sql("已有 canonical Artifact，但 AnalysisJob 无法标记完成。")
                    }
                }
                dailyReview = String(data: existing.content, encoding: .utf8)
                status = "已有相同输入的 canonical Artifact；跳过重复分析"
                errorMessage = nil
                return
            }

            let jobID = RiverAnalysisJobScheduler.jobID(
                deviceID: database.deviceID,
                logicalKey: logicalKey,
                artifactType: .dailyReview,
                inputFrontier: frontier,
                pipelineVersion: jobPipeline,
                promptVersion: promptVersion,
                requestFingerprint: requestFingerprint
            )
            let previous = try database.analysisJobs().first { $0.id == jobID }
            activeJob = RiverAnalysisJob(
                id: jobID,
                logicalKey: logicalKey,
                artifactType: .dailyReview,
                inputFrontier: frontier,
                priority: 100,
                status: .queued,
                createdAt: previous?.createdAt ?? Date(),
                attempt: previous?.attempt ?? 0,
                originDeviceID: database.deviceID,
                pipelineVersion: jobPipeline,
                promptVersion: promptVersion,
                requestFingerprint: requestFingerprint
            )
            guard let queuedJob = activeJob, try database.saveAnalysisJob(queuedJob) else {
                throw RiverLocalDatabaseError.sql("AnalysisJob 无法持久化。")
            }
            let runningJob = queuedJob.transitioning(to: .running)
            activeJob = runningJob
            guard try database.saveAnalysisJob(runningJob) else {
                throw RiverLocalDatabaseError.sql("AnalysisJob 无法进入 running 状态。")
            }

            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 90
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try JSONEncoder().encode(requestBody)
            status = "正在分析"
            errorMessage = photoAnalysisWarning

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
                throw IPhoneAIError.api("API 返回 \((response as? HTTPURLResponse)?.statusCode ?? -1)。\(detail)")
            }
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard let answer = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
                  !answer.isEmpty else { throw IPhoneAIError.api("API 没有返回分析内容。") }

            let stamp = try database.nextManifestStamp()
            let evidence = selected.map { $0.0.id.uuidString }
            let structured = RiverDayAnalysisResponse.decode(answer)
            let verifiedDigest = structured?.digest(dayKey: dayKey, events: selected.map { $0.0 })
            let review = structured.map { result in
                ([result.overview] + (verifiedDigest?.segments ?? []).map { $0.title + "\n" + $0.summary }).joined(separator: "\n\n")
            } ?? answer
            guard !review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw IPhoneAIError.api("AI 返回了空的活动分析。") }
            let content = Data(review.utf8)
            let artifactStatus: ArtifactStatus = try database.currentInputFrontier() != frontier
                ? .stale
                : (database.isCurrentStateVerified() ? .current : .provisional)
            let revision = RiverArtifactRevision(
                id: UUID().uuidString.lowercased(),
                logicalKey: logicalKey,
                kind: .dailyReview,
                revisionNumber: try database.nextArtifactRevisionNumber(logicalKey: logicalKey, kind: .dailyReview),
                originDeviceID: database.deviceID,
                clock: stamp.clock,
                inputFrontier: frontier,
                inputSnapshotHash: artifactInputFingerprint,
                pipelineVersion: pipelineVersion,
                promptVersion: promptVersion,
                modelProvider: provider,
                modelIdentifier: requestModel,
                content: content,
                contentHash: Self.sha256(content),
                status: artifactStatus,
                dependencies: evidence.map {
                    ArtifactDependency(type: "event", id: $0, rangeStart: start, rangeEnd: end)
                } + selectedJournals.map { journal in
                    ArtifactDependency(type: "shared_record", id: "journal:\(journal.dayKey)", rangeStart: start, rangeEnd: end)
                } + [ArtifactDependency(type: "time_range", id: dayKey, rangeStart: start, rangeEnd: end)]
            )
            try database.insertArtifactRevision(revision)
            if let digest = verifiedDigest {
                if !digest.segments.isEmpty {
                    let digestData = try JSONEncoder().encode(digest)
                    let digestKey = "iphone-analysis|d-" + dayKey
                    let digestStamp = try database.nextManifestStamp()
                    try database.insertArtifactRevision(RiverArtifactRevision(
                        id: UUID().uuidString.lowercased(), logicalKey: digestKey, kind: .semanticTimeline,
                        revisionNumber: try database.nextArtifactRevisionNumber(logicalKey: digestKey, kind: .semanticTimeline),
                        originDeviceID: database.deviceID, clock: digestStamp.clock, inputFrontier: frontier,
                        inputSnapshotHash: artifactInputFingerprint, pipelineVersion: pipelineVersion,
                        promptVersion: promptVersion, modelProvider: provider, modelIdentifier: requestModel,
                        content: digestData, contentHash: Self.sha256(digestData), status: artifactStatus,
                        dependencies: revision.dependencies))
                }
            }
            let inputStillCurrent = try database.currentInputFrontier() == frontier
            activeJob = activeJob?.transitioning(to: inputStillCurrent ? .succeeded : .superseded)
            if let activeJob { try database.saveAnalysisJob(activeJob) }
            database.refreshTimeline()
            reloadDailyReview()
            if revision.status == .stale {
                status = "分析完成时有新事件到达；已排入新前沿的重算"
                if automaticRecomputeDepth < 3 && (localHost || allowsNetworkAnalysis) {
                    let nextDepth = automaticRecomputeDepth + 1
                    Task { @MainActor [weak self] in
                        await Task.yield()
                        await self?.analyzeToday(automaticRecomputeDepth: nextDepth,
                                                 automaticTrigger: automaticTrigger, analysisDate: analysisDate)
                    }
                }
            } else {
                status = database.isCurrentStateVerified() ? "已分析 · 本机状态已核对" : "已分析 · 等待其他设备合并"
                if automaticTrigger {
                    UserDefaults.standard.set(Date().timeIntervalSince1970,
                                              forKey: "river.ai.lastAutomaticAnalysisAt")
                }
            }
        } catch {
            var failureStateSaved = true
            if let activeJob {
                failureStateSaved = (try? database.saveAnalysisJob(
                    activeJob.transitioning(to: .failed, error: error.localizedDescription)
                )) == true
            }
            status = "分析失败"
            errorMessage = failureStateSaved
                ? error.localizedDescription
                : "分析失败，且失败状态无法写入本机任务记录：\(error.localizedDescription)"
        }
    }

    /// Answers a question only from context selected by the caller. The caller
    /// applies the same per-category privacy switches used by daily analysis.
    func ask(question: String, context: String) async throws -> String {
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestURL = Self.normalizedChatCompletionsURL(from: normalizedEndpoint) else {
            throw IPhoneAIError.api("请检查 AI 服务地址；可填写 DeepSeek 基础地址或完整 Chat Completions 地址。")
        }
        let localHost = ["localhost", "127.0.0.1", "::1"].contains(requestURL.host?.lowercased() ?? "")
        guard requestURL.scheme?.lowercased() == "https" || (localHost && requestURL.scheme?.lowercased() == "http") else {
            throw IPhoneAIError.api("网络 AI 必须使用 HTTPS；只有本机模型可以使用 HTTP。")
        }
        guard localHost || allowsNetworkAnalysis else {
            throw IPhoneAIError.api("尚未同意向网络 AI 发送个人数据。")
        }
        let requestModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestModel.isEmpty else { throw IPhoneAIError.api("请先填写模型名称。") }
        let apiKey = localHost ? nil : try RiverSecureStore.loadNetworkAIKey()
        let system = "你是 River Diary 的个人记忆助手。只使用给出的资料回答；明确区分观察、用户确认与推断；资料没有提到时直接说不知道，不要补造人物、活动或数字。回答中文，简洁并引用资料中的日期或来源标签。"
        let user = "用户的问题：\n\(question)\n\n当前可用资料：\n\(context.isEmpty ? "没有找到可用资料。" : context)"
        let body = ChatCompletionRequest(
            model: requestModel,
            messages: [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: user)],
            temperature: 0.2,
            max_tokens: 650
        )
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw IPhoneAIError.api("AI 服务返回 \((response as? HTTPURLResponse)?.statusCode ?? -1)。\(detail)")
        }
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let answer = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !answer.isEmpty else { throw IPhoneAIError.api("AI 服务没有返回回答。") }
        return answer
    }

    private func analyzePhotoGroups(_ inputs: [IPhonePhotoAIInput], start: Date, end: Date,
                                    endpoint: URL, model: String, apiKey: String?) async throws {
        guard !inputs.isEmpty else { return }
        let ordered = inputs.sorted { $0.capturedAt < $1.capturedAt }
        var groups: [[IPhonePhotoAIInput]] = []
        for input in ordered {
            if let last = groups.last?.last,
               input.capturedAt.timeIntervalSince(last.capturedAt) <= 35 * 60 {
                groups[groups.count - 1].append(input)
            } else {
                groups.append([input])
            }
        }

        let oldEvents = try database.events(from: start, to: end)
        let completed = Set<String>(oldEvents.compactMap { event in
            guard event.kind == "media.analysis" || event.kind == "meal.estimate",
                  let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload) else { return nil }
            return payload.mediaAnalysisFingerprint
        })
        var appended = false

        for group in groups.prefix(4) {
            let tokens = group.map(\.assetToken).sorted()
            let groupID = Self.sha256(Data(tokens.joined(separator: "|").utf8))
            let imageDigest = group.map { Self.sha256($0.jpegData) }.joined(separator: "|")
            let fingerprint = Self.sha256(Data("photo-analysis-v1|\(endpoint.absoluteString)|\(model)|\(groupID)|\(imageDigest)".utf8))
            guard !completed.contains(fingerprint) else { continue }

            let photoNotes = group.enumerated().map { index, input in
                "照片 \(index + 1)：\(input.capturedAt.formatted(date: .omitted, time: .shortened))；本机线索：\(input.localSummary)"
            }.joined(separator: "\n")
            let prompt = "分析这一组同一时段的照片。它们可能是同一顿饭的不同角度，不能重复累计。照片只证明画面内容，不能证明用户确实吃了或到访。若能看出食物，请估计整组食物的总热量范围；份量、配料不清时扩大范围或返回 null，绝不给精确数值。景点照片只描述画面，不宣称用户已完成游览。只返回 JSON：{\"category\":\"food|landmark|scene\",\"title\":\"简短标题\",\"foods\":[\"可辨认食物\"],\"calories_min\":整数或null,\"calories_max\":整数或null,\"portion_note\":\"估算依据/不确定处\"}。\n\(photoNotes)"
            var parts: [ChatMessagePart] = [.textPart(prompt)]
            for input in group {
                let dataURL = "data:image/jpeg;base64,\(input.jpegData.base64EncodedString())"
                parts.append(.imagePart(dataURL))
            }
            let requestBody = ChatCompletionRequest(
                model: model,
                messages: [
                    ChatMessage(role: "system", content: "依据照片做保守视觉描述。餐食总热量只能给区间并标明估算，不做医疗或营养建议。严格返回 JSON。"),
                    ChatMessage(role: "user", content: .parts(parts))
                ],
                temperature: 0.1,
                max_tokens: 350
            )
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try JSONEncoder().encode(requestBody)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw IPhoneAIError.api("照片模型暂不可用（\((response as? HTTPURLResponse)?.statusCode ?? -1)）。")
            }
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard let raw = decoded.choices.first?.message.content,
                  let result = Self.decodePhotoResult(raw) else {
                throw IPhoneAIError.api("照片模型未返回可保存的结构化描述。")
            }

            let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let foodNames = (result.foods ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.prefix(6)
            let caloriesValid = result.category == "food"
                && (0...4000).contains(result.calories_min ?? -1)
                && (0...4000).contains(result.calories_max ?? -1)
                && (result.calories_max ?? -1) >= (result.calories_min ?? Int.max)
            let summary = foodNames.isEmpty ? title : "\(title)：\(foodNames.joined(separator: "、"))"
            let payload = RiverEventPayload(
                mediaSummary: summary,
                mediaCategory: result.category,
                mediaGroupID: groupID,
                mediaSourceTokens: tokens,
                mediaAnalysisFingerprint: fingerprint,
                photoCount: group.count,
                mealCaloriesLowerBound: caloriesValid ? result.calories_min : nil,
                mealCaloriesUpperBound: caloriesValid ? result.calories_max : nil,
                mealEstimateNote: caloriesValid ? result.portion_note : nil
            )
            let payloadData = try JSONEncoder().encode(payload)
            let payloadHash = Self.sha256(payloadData)
            let kind = result.category == "food" ? "meal.estimate" : "media.analysis"
            _ = try database.append(
                id: RiverStableIdentifier.uuid(namespace: "photo-analysis|\(database.deviceID.rawValue)",
                                               key: "\(groupID)|\(fingerprint)|\(payloadHash)"),
                source: "network_photo_ai",
                kind: kind,
                payload: payload,
                observedAt: group[0].capturedAt,
                sourceHash: payloadHash
            )
            appended = true
        }
        if appended { database.refreshTimeline() }
    }

    private static func decodePhotoResult(_ response: String) -> PhotoVisionResult? {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```json") { text = String(text.dropFirst(7)) }
        else if text.hasPrefix("```") { text = String(text.dropFirst(3)) }
        if text.hasSuffix("```") { text = String(text.dropLast(3)) }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { return nil }
        let json = Data(text[start...end].utf8)
        guard let result = try? JSONDecoder().decode(PhotoVisionResult.self, from: json),
              ["food", "landmark", "scene"].contains(result.category.lowercased()) else { return nil }
        return result
    }

    func reloadDailyReview() {
        let logicalKey = RiverCanonicalArtifactKey.dailyReview(dayKey: Self.dayKey(Calendar.current.startOfDay(for: Date())))
        let revisions = (try? database.canonicalArtifactRevisions()) ?? []
        guard let revision = revisions.first(where: { $0.logicalKey == logicalKey && $0.kind == .dailyReview }) else {
            dailyReview = nil
            status = "尚未分析"
            return
        }
        dailyReview = String(data: revision.content, encoding: .utf8)
        switch revision.status {
        case .stale: status = "依据有更新 · 需要重新分析"
        case .provisional: status = "已生成 · 等待其他设备合并"
        case .current: status = "已分析"
        case .superseded: status = "已有更新版本"
        }
    }

    private func resumeQueuedDailyReviewIfNeeded() {
        let dayKey = Self.dayKey(Calendar.current.startOfDay(for: Date()))
        let logicalKey = RiverCanonicalArtifactKey.dailyReview(dayKey: dayKey)
        let jobs = (try? database.analysisJobs()) ?? []
        let frontier = try? database.currentInputFrontier()
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestURL = Self.normalizedChatCompletionsURL(from: normalizedEndpoint)
        let localHost = ["localhost", "127.0.0.1", "::1"].contains(requestURL?.host?.lowercased() ?? "")
        let provider = localHost ? "local-openai-compatible" : "network-openai-compatible"
        let requestModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointIdentity = requestURL?.absoluteString ?? normalizedEndpoint
        let endpointFingerprint = Self.sha256(Data(endpointIdentity.utf8))
        let expectedPipeline = "\(pipelineVersion)|\(provider)|\(requestModel)|\(endpointFingerprint)"
        let canRunAutomatically = localHost || (allowsNetworkAnalysis && hasAPIKey)
        let canonical = ((try? database.canonicalArtifactRevisions()) ?? []).first {
            $0.logicalKey == logicalKey && $0.kind == .dailyReview
        }
        let hasCurrentArtifact = canonical.map { $0.status != .stale } ?? false
        let needsCurrentInputRebuild = frontier.map {
            RiverAnalysisJobScheduler.needsCurrentInputRebuild(
                jobs,
                logicalKey: logicalKey,
                currentFrontier: $0,
                pipelineVersion: expectedPipeline,
                hasCurrentArtifact: hasCurrentArtifact
            )
        } ?? false
        if needsCurrentInputRebuild, !canRunAutomatically {
            status = "输入资料已有更新；重新同意网络分析后会按最新资料重建。"
            errorMessage = nil
            return
        }
        if let frontier {
            for job in jobs where job.logicalKey == logicalKey
                && (job.status == .queued || job.status == .running)
                && (job.inputFrontier != frontier || job.pipelineVersion != expectedPipeline) {
                _ = try? database.saveAnalysisJob(job.transitioning(to: .superseded))
            }
        }
        let currentJobs = (try? database.analysisJobs()) ?? jobs
        let hasPendingJob = currentJobs.contains {
            $0.logicalKey == logicalKey && $0.inputFrontier == frontier && $0.pipelineVersion == expectedPipeline
                && ($0.status == .queued || $0.status == .running)
        }
        let staleArtifact = canonical?.status == .stale
        guard hasPendingJob || staleArtifact || needsCurrentInputRebuild else { return }
        if !hasPendingJob, let frontier,
           currentJobs.contains(where: {
               $0.logicalKey == logicalKey && $0.inputFrontier == frontier && $0.pipelineVersion == expectedPipeline
                   && ($0.status == .failed || $0.status == .succeeded)
           }) { return }
        guard canRunAutomatically else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            await self?.analyzeToday()
        }
    }

    private func inputFrontierChanged() -> Bool {
        guard let frontier = try? database.currentInputFrontier() else { return false }
        defer { lastObservedFrontier = frontier }
        return lastObservedFrontier != frontier
    }

    private func scheduleAutomaticDailyReview(configurationChanged: Bool = false) {
        guard let requestURL = Self.normalizedChatCompletionsURL(from: endpoint),
              let scheme = requestURL.scheme?.lowercased(),
              let host = requestURL.host?.lowercased() else { return }
        let localHost = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (localHost && scheme == "http"),
              localHost || (allowsNetworkAnalysis && hasAPIKey) else { return }
        guard let frontier = try? database.currentInputFrontier() else { return }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let dayKey = Self.dayKey(start)
        let hasEvents = (try? database.events(from: start, to: end).isEmpty == false) ?? false
        let hasJournal = database.sharedUserRecords.contains {
            $0.kind == .journalEntry && $0.status == "current" && $0.logicalKey == dayKey
                && !($0.journalEntryContent?.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        guard hasEvents || hasJournal else { return }

        let requestModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestModel.isEmpty else { return }
        let key = Self.sha256(Data([
            frontier.stableKey, requestURL.absoluteString, requestModel,
            includePlaces.description, includeHealth.description, includeManualText.description,
            includePhotoObservations.description, allowsPhotoAI.description,
            includeSharedMemories.description
        ].joined(separator: "|").utf8))
        if configurationChanged {
            lastAutomaticAttemptKey = nil
            UserDefaults.standard.removeObject(forKey: "river.ai.lastAutomaticAttemptKey")
        }
        guard lastAutomaticAttemptKey != key else { return }

        if !configurationChanged,
           let existing = (try? database.canonicalArtifactRevisions())?.first(where: {
               $0.logicalKey == RiverCanonicalArtifactKey.dailyReview(dayKey: dayKey)
                   && $0.kind == .dailyReview
           }), existing.inputFrontier == frontier, existing.modelIdentifier == requestModel,
           existing.status != .stale {
            return
        }

        automaticAnalysisTask?.cancel()
        automaticAnalysisTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            while self.isGenerating {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
            let lastRun = UserDefaults.standard.double(forKey: "river.ai.lastAutomaticAnalysisAt")
            let cooldown = max(0, lastRun + 300 - Date().timeIntervalSince1970)
            if cooldown > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(cooldown * 1_000_000_000)) } catch { return }
            }
            guard !Task.isCancelled, self.automaticAnalysisKey() == key,
                  self.lastAutomaticAttemptKey != key else { return }
            self.lastAutomaticAttemptKey = key
            UserDefaults.standard.set(key, forKey: "river.ai.lastAutomaticAttemptKey")
            await self.analyzeToday(automaticTrigger: true)
        }
    }

    /// Foreground/lifecycle ticks also observe the day boundary without asking the user to generate a diary.
    func refreshAutomaticSchedule() {
        reloadDailyReview()
        resumeQueuedDailyReviewIfNeeded()
        scheduleAutomaticDailyReview()
    }

    private func automaticAnalysisKey() -> String? {
        guard let frontier = try? database.currentInputFrontier(),
              let url = Self.normalizedChatCompletionsURL(from: endpoint) else { return nil }
        return Self.sha256(Data([
            Self.dayKey(Calendar.current.startOfDay(for: .now)), frontier.stableKey, url.absoluteString, model.trimmingCharacters(in: .whitespacesAndNewlines),
            includePlaces.description, includeHealth.description, includeManualText.description,
            includePhotoObservations.description, allowsPhotoAI.description,
            includeSharedMemories.description
        ].joined(separator: "|").utf8))
    }

    private static func normalizedChatCompletionsURL(from rawEndpoint: String) -> URL? {
        guard var components = URLComponents(string: rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased() else { return nil }
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path == "/" { path = "" }
        let lowerPath = path.lowercased()

        if host == "api.deepseek.com" {
            if lowerPath.hasSuffix("/v1/chat/completions") {
                path = String(path.dropLast("/v1/chat/completions".count)) + "/chat/completions"
            } else if !lowerPath.hasSuffix("/chat/completions") {
                if lowerPath.hasSuffix("/v1") { path = String(path.dropLast(3)) }
                path += "/chat/completions"
            }
        } else if !lowerPath.hasSuffix("/chat/completions") {
            if path.isEmpty || path == "/" {
                path = "/v1/chat/completions"
            } else if ["/v1", "/v4", "/v4.0"].contains(where: lowerPath.hasSuffix)
                || ["/v1/", "/v4/", "/compatible-mode/", "/api/paas/"].contains(where: lowerPath.contains) {
                path += "/chat/completions"
            } else {
                path += "/v1/chat/completions"
            }
        }
        components.path = path
        guard let url = components.url, let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            return nil
        }
        return url
    }

    private static func promptLine(_ event: RiverEvent, _ payload: RiverEventPayload) -> String {
        let time = event.observedAt.formatted(date: .omitted, time: .shortened)
        let detail: String
        if event.kind == "media.photoObservation", let summary = payload.mediaSummary {
            detail = "照片线索（\(payload.mediaCategory ?? "场景")）：\(summary)"
        } else if event.kind == "meal.estimate", let summary = payload.mediaSummary {
            let range = if let low = payload.mealCaloriesLowerBound, let high = payload.mealCaloriesUpperBound {
                "照片估算约 \(low)–\(high) 千卡（份量可能有误差）"
            } else { "热量未能估算" }
            detail = "\(summary) · \(range)"
        } else if event.kind == "media.analysis", let summary = payload.mediaSummary {
            detail = "照片内容：\(summary)"
        } else if event.kind == "mobility.activity", let mode = payload.movementMode {
            detail = "运动识别：\(IPhoneMotionCollector.label(for: mode))"
        } else if let app = payload.appName {
            detail = "应用 \(app) \(event.kind.hasSuffix("close") || event.kind.hasSuffix("closed") ? "离开" : "活动")"
        } else if event.kind == "location.placeCandidate", let candidates = payload.mapCandidates, !candidates.isEmpty {
            detail = "附近地点候选：\(candidates.prefix(4).map(\.choiceLabel).joined(separator: "、"))"
        } else if event.kind.hasPrefix("location."), let place = payload.locationName {
            detail = "地点 \(place)"
        } else if event.kind.hasPrefix("health."), let metrics = payload.metrics {
            detail = [metrics.steps.map { "步数 \($0)" }, metrics.sleepHours.map { "睡眠 \(String(format: "%.1f", $0)) 小时" }]
                .compactMap { $0 }.joined(separator: "，")
        } else if let text = payload.text {
            detail = "手动记录：\(text.prefix(160))"
        } else {
            detail = event.kind
        }
        return "\(time) · \(detail)"
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct PhotoVisionResult: Decodable {
    let category: String
    let title: String
    let foods: [String]?
    let calories_min: Int?
    let calories_max: Int?
    let portion_note: String?
}

private enum IPhoneAIError: LocalizedError {
    case api(String)

    var errorDescription: String? {
        switch self {
        case .api(let message): message
        }
    }
}

private enum ChatMessageContent: Encodable {
    case text(String)
    case parts([ChatMessagePart])

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .parts(let values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        }
    }
}

private struct ChatMessagePart: Encodable {
    struct ImageURL: Encodable {
        let url: String
        let detail: String
    }

    let type: String
    let text: String?
    let image_url: ImageURL?

    static func textPart(_ value: String) -> Self { Self(type: "text", text: value, image_url: nil) }
    static func imagePart(_ dataURL: String) -> Self {
        Self(type: "image_url", text: nil, image_url: ImageURL(url: dataURL, detail: "high"))
    }
}

private struct ChatMessage: Encodable {
    let role: String
    let content: ChatMessageContent

    init(role: String, content: String) {
        self.role = role
        self.content = .text(content)
    }

    init(role: String, content: ChatMessageContent) {
        self.role = role
        self.content = content
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let max_tokens: Int
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}
