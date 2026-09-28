import CryptoKit
import Combine
import Foundation
import RiverDiaryCore
import SwiftUI

@MainActor
final class IPhoneAIStore: ObservableObject {
    @Published var endpoint: String {
        didSet { UserDefaults.standard.set(endpoint, forKey: "river.ai.endpoint") }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "river.ai.model") }
    }
    @Published var includePlaces: Bool {
        didSet { UserDefaults.standard.set(includePlaces, forKey: "river.ai.includePlaces") }
    }
    @Published var includeHealth: Bool {
        didSet { UserDefaults.standard.set(includeHealth, forKey: "river.ai.includeHealth") }
    }
    @Published var includeManualText: Bool {
        didSet { UserDefaults.standard.set(includeManualText, forKey: "river.ai.includeManualText") }
    }
    @Published var allowsNetworkAnalysis: Bool {
        didSet { UserDefaults.standard.set(allowsNetworkAnalysis, forKey: "river.ai.networkConsent") }
    }
    @Published var apiKeyInput = ""
    @Published private(set) var hasAPIKey = RiverSecureStore.hasNetworkAIKey()
    @Published private(set) var isGenerating = false
    @Published private(set) var status = "尚未分析"
    @Published private(set) var errorMessage: String?
    @Published private(set) var dailyReview: String?

    private let database: RiverLocalDatabase
    private let session: URLSession
    private var databaseRevisionObserver: AnyCancellable?
    private let pipelineVersion = "1.0"
    private let promptVersion = "1"

    init(database: RiverLocalDatabase, session: URLSession = .shared) {
        self.database = database
        self.session = session
        endpoint = UserDefaults.standard.string(forKey: "river.ai.endpoint") ?? "https://api.openai.com/v1/chat/completions"
        model = UserDefaults.standard.string(forKey: "river.ai.model") ?? "gpt-4o-mini"
        includePlaces = UserDefaults.standard.bool(forKey: "river.ai.includePlaces")
        includeHealth = UserDefaults.standard.bool(forKey: "river.ai.includeHealth")
        includeManualText = UserDefaults.standard.bool(forKey: "river.ai.includeManualText")
        allowsNetworkAnalysis = UserDefaults.standard.bool(forKey: "river.ai.networkConsent")
        databaseRevisionObserver = database.$dataRevision.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadDailyReview()
                self?.resumeQueuedDailyReviewIfNeeded()
            }
        }
        reloadDailyReview()
        resumeQueuedDailyReviewIfNeeded()
    }

    func saveAPIKey() {
        guard !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try RiverSecureStore.saveNetworkAIKey(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines))
            hasAPIKey = true
            apiKeyInput = ""
            errorMessage = nil
        } catch {
            errorMessage = "API 密钥无法保存在钥匙串：\(error.localizedDescription)"
        }
    }

    func removeAPIKey() {
        do {
            try RiverSecureStore.deleteNetworkAIKey()
            hasAPIKey = false
            apiKeyInput = ""
            errorMessage = nil
            status = "网络 AI 密钥已移除"
        } catch {
            errorMessage = "网络 AI 密钥无法从钥匙串移除：\(error.localizedDescription)"
        }
    }

    func analyzeToday(automaticRecomputeDepth: Int = 0) async {
        guard !isGenerating else { return }
        guard let requestURL = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "请输入有效的 OpenAI 兼容 API 地址。"
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
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请先填写模型名称。"
            status = "配置无效"
            return
        }

        var activeJob: RiverAnalysisJob?
        do {
            let apiKey = localHost ? nil : try RiverSecureStore.loadNetworkAIKey()
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: Date())
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            let events = try database.events(from: start, to: end)
            guard !events.isEmpty else {
                status = "等待真实事件"
                errorMessage = "今天还没有可分析的本机或已同步事件。"
                return
            }

            let selected = events.compactMap { event -> (RiverEvent, RiverEventPayload)? in
                guard let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload) else { return nil }
                if event.kind.hasPrefix("location.") && !includePlaces { return nil }
                if event.kind.hasPrefix("health.") && !includeHealth { return nil }
                if payload.text != nil && !includeManualText { return nil }
                return (event, payload)
            }
            guard !selected.isEmpty else {
                status = "没有所选范围内的分析资料"
                errorMessage = "当前隐私选项筛掉了今天的全部事件。"
                return
            }

            // Capture the frontier before awaiting the provider so events that
            // arrive during the request are not claimed as model input.
            let frontier = try database.currentInputFrontier()
            let dayKey = Self.dayKey(start)
            let logicalKey = RiverCanonicalArtifactKey.dailyReview(dayKey: dayKey)
            let provider = localHost ? "local-openai-compatible" : "network-openai-compatible"
            if let existing = try database.canonicalArtifactRevisions().first(where: {
                $0.logicalKey == logicalKey && $0.kind == .dailyReview
                    && $0.inputFrontier == frontier && $0.pipelineVersion == pipelineVersion
                    && $0.promptVersion == promptVersion && $0.status != .stale
            }) {
                if let queued = try database.analysisJobs().first(where: {
                    $0.logicalKey == logicalKey && $0.inputFrontier == frontier
                        && ($0.status == .queued || $0.status == .running)
                }) {
                    try database.saveAnalysisJob(queued.transitioning(to: .succeeded))
                }
                dailyReview = String(data: existing.content, encoding: .utf8)
                status = "已有相同输入的 canonical Artifact；跳过重复分析"
                errorMessage = nil
                return
            }

            let jobPipeline = "\(pipelineVersion)|\(provider)|\(model)"
            let jobID = RiverAnalysisJobScheduler.jobID(
                deviceID: database.deviceID,
                logicalKey: logicalKey,
                artifactType: .dailyReview,
                inputFrontier: frontier,
                pipelineVersion: jobPipeline,
                promptVersion: promptVersion
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
                promptVersion: promptVersion
            )
            guard let queuedJob = activeJob, try database.saveAnalysisJob(queuedJob) else {
                throw RiverLocalDatabaseError.sql("AnalysisJob 无法持久化。")
            }
            let runningJob = queuedJob.transitioning(to: .running)
            activeJob = runningJob
            guard try database.saveAnalysisJob(runningJob) else {
                throw RiverLocalDatabaseError.sql("AnalysisJob 无法进入 running 状态。")
            }

            let lines = selected.map { event, payload in Self.promptLine(event, payload) }
            let system = "你是 River Diary 的个人日记分析器。只根据用户提供的事件写一段简洁、谨慎的日终回顾；区分观察与推断，不补造事件，不推断医学结论，不复述坐标。输出中文正文，不需要标题或 JSON。"
            let user = "请总结今天的时间线，指出有依据的主要活动和仍不确定的部分。\n\n事件：\n" + lines.joined(separator: "\n")
            let requestBody = ChatCompletionRequest(
                model: model,
                messages: [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: user)],
                temperature: 0.2,
                max_tokens: 900
            )
            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 90
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try JSONEncoder().encode(requestBody)
            isGenerating = true
            status = "正在分析"
            errorMessage = nil
            defer { isGenerating = false }

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
            let fingerprintEncoder = JSONEncoder()
            fingerprintEncoder.outputFormatting = [.sortedKeys]
            let sourceText = try selected.map { event, payload in
                "\(event.id.uuidString)|\(String(decoding: try fingerprintEncoder.encode(payload), as: UTF8.self))"
            }.joined(separator: "\n")
            let sourceHash = Self.sha256(Data("\(frontier.stableKey)|\(sourceText)".utf8))
            let content = Data(answer.utf8)
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
                inputSnapshotHash: sourceHash,
                pipelineVersion: pipelineVersion,
                promptVersion: promptVersion,
                modelProvider: provider,
                modelIdentifier: model,
                content: content,
                contentHash: Self.sha256(content),
                status: artifactStatus,
                dependencies: evidence.map {
                    ArtifactDependency(type: "event", id: $0, rangeStart: start, rangeEnd: end)
                } + [ArtifactDependency(type: "time_range", id: dayKey, rangeStart: start, rangeEnd: end)]
            )
            try database.insertArtifactRevision(revision)
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
                        await self?.analyzeToday(automaticRecomputeDepth: nextDepth)
                    }
                }
            } else {
                status = database.isCurrentStateVerified() ? "已分析 · 本机状态已核对" : "已分析 · 等待其他设备合并"
            }
        } catch {
            if let activeJob {
                try? database.saveAnalysisJob(activeJob.transitioning(to: .failed, error: error.localizedDescription))
            }
            status = "分析失败"
            errorMessage = error.localizedDescription
        }
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
        if let frontier {
            for job in jobs where job.logicalKey == logicalKey
                && (job.status == .queued || job.status == .running)
                && job.inputFrontier != frontier {
                try? database.saveAnalysisJob(job.transitioning(to: .superseded))
            }
        }
        let hasPendingJob = jobs.contains {
            $0.logicalKey == logicalKey && $0.inputFrontier == frontier
                && ($0.status == .queued || $0.status == .running)
        }
        let staleArtifact = ((try? database.canonicalArtifactRevisions()) ?? []).first {
            $0.logicalKey == logicalKey && $0.kind == .dailyReview && $0.status == .stale
        }
        guard hasPendingJob || staleArtifact != nil else { return }
        if !hasPendingJob, let frontier,
           jobs.contains(where: {
               $0.logicalKey == logicalKey && $0.inputFrontier == frontier
                   && ($0.status == .failed || $0.status == .succeeded)
           }) { return }
        let requestURL = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
        let localHost = ["localhost", "127.0.0.1", "::1"].contains(requestURL?.host?.lowercased() ?? "")
        guard localHost || allowsNetworkAnalysis else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            await self?.analyzeToday()
        }
    }

    private static func promptLine(_ event: RiverEvent, _ payload: RiverEventPayload) -> String {
        let time = event.observedAt.formatted(date: .omitted, time: .shortened)
        let detail: String
        if let app = payload.appName {
            detail = "应用 \(app) \(event.kind.hasSuffix("close") || event.kind.hasSuffix("closed") ? "离开" : "活动")"
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

private enum IPhoneAIError: LocalizedError {
    case api(String)

    var errorDescription: String? {
        switch self {
        case .api(let message): message
        }
    }
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
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
