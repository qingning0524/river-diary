import Foundation
import LocalAuthentication
import Security
@MainActor
final class AIAssistantStore: ObservableObject {
    @Published var includeTitles: Bool {
        didSet { UserDefaults.standard.set(includeTitles, forKey: "ai.footprint.includeTitles") }
    }

    @Published private(set) var profiles: [AIProfile] = [] {
        didSet { persistProfiles() }
    }

    @Published var selectedProfileID: String? {
        didSet {
            UserDefaults.standard.set(selectedProfileID, forKey: "ai.footprint.selectedProfile")
            availableModels = []
            modelMessage = nil
            apiKeyInput = ""
            hasAPIKey = AIKeychain.hasKey(for: selectedProfileID ?? "")
            lastRequestRecord = nil
        }
    }

    @Published var apiKeyInput = ""
    @Published private(set) var hasAPIKey = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingModels = false
    @Published private(set) var availableModels: [String] = []
    @Published private(set) var modelMessage: String?
    @Published private(set) var answer: String?
    @Published private(set) var lastQuestion: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastCompletedAt: Date?
    @Published private(set) var lastRequestRecord: AIRequestRecord?
    @Published private(set) var lastAutomaticAnalysisDate: String? {
        didSet { UserDefaults.standard.set(lastAutomaticAnalysisDate, forKey: "ai.footprint.lastAutomaticAnalysisDate") }
    }
    @Published private(set) var taskStates: [AITask: AITaskState] = [:]

    private var memorySearchCache: [String: String] = [:]
    private var taskRequestIDs: [AITask: UUID] = [:]
    private let providedAnalysisStore: V2Store?
    private lazy var analysisStore: V2Store = providedAnalysisStore ?? V2Store()
    private static let contextDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private var oldProviderDefaults: [String] {
        AIProvider.allCases.flatMap { [$0.defaultEndpoint, $0.defaultModel] }
    }

    var activeProfile: AIProfile? {
        profiles.first { $0.id == selectedProfileID } ?? profiles.first
    }

    var provider: AIProvider {
        get { activeProfile?.provider ?? .openAICompatible }
        set { updateActiveProfile { profile in profile.provider = newValue } }
    }

    var endpoint: String {
        get { activeProfile?.endpoint ?? "" }
        set { updateActiveProfile { $0.endpoint = newValue } }
    }

    var model: String {
        get { activeProfile?.model ?? "" }
        set { updateActiveProfile { $0.model = newValue } }
    }

    var profileName: String {
        get { activeProfile?.name ?? "默认模型" }
        set { updateActiveProfile { $0.name = newValue } }
    }

    var providerRequiresAPIKey: Bool {
        provider.requiresAPIKey
    }

    var isConfigured: Bool {
        let hasEndpoint = !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasModel = !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let keyReady = !providerRequiresAPIKey || hasAPIKey
        return hasEndpoint && hasModel && keyReady
    }

    var canTestConnection: Bool {
        let hasEndpoint = !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasModel = !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let keyReady = !providerRequiresAPIKey || hasAPIKey || !apiKeyInput.isEmpty
        return hasEndpoint && hasModel && keyReady
    }

    var analysisReady: Bool {
        isConfigured
    }

    var hasVerifiedConnection: Bool {
        guard isConfigured, hasAPIKey, let record = lastRequestRecord else { return false }
        return record.success && record.provider == provider.label && record.model == model
    }

    var requestSummary: String? {
        guard let record = lastRequestRecord else { return nil }
        let time = record.date.formatted(date: .omitted, time: .shortened)
        return "\(time) · \(record.model) · \(record.success ? "成功" : "失败")"
    }

    init(v2Store: V2Store? = nil) {
        providedAnalysisStore = v2Store
        includeTitles = UserDefaults.standard.bool(forKey: "ai.footprint.includeTitles")
        loadProfiles()
        selectedProfileID = UserDefaults.standard.string(forKey: "ai.footprint.selectedProfile")
            .flatMap { id in profiles.contains { $0.id == id } ? id : nil }
            ?? profiles.first?.id
        hasAPIKey = selectedProfileID.map { AIKeychain.hasKey(for: $0) } ?? false
        lastRequestRecord = UserDefaults.standard.data(forKey: "ai.footprint.lastRequest")
            .flatMap { try? JSONDecoder().decode(AIRequestRecord.self, from: $0) }
        lastAutomaticAnalysisDate = UserDefaults.standard.string(forKey: "ai.footprint.lastAutomaticAnalysisDate")
    }

    private func loadProfiles() {
        if let raw = UserDefaults.standard.data(forKey: "ai.footprint.profiles") {
            if var decoded = try? JSONDecoder().decode([AIProfile].self, from: raw), !decoded.isEmpty {
                for index in decoded.indices {
                    let endpoint = decoded[index].endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !endpoint.isEmpty,
                       !endpoint.lowercased().hasPrefix("https://"),
                       !endpoint.lowercased().hasPrefix("http://") {
                        let scheme = decoded[index].provider == .ollama || decoded[index].provider == .lmStudio ? "http://" : "https://"
                        decoded[index].endpoint = scheme + endpoint
                    }
                }
                profiles = decoded
                return
            }
            // 配置数据存在但解码失败时，先把原始字节归档到带时间戳的键里：
            // profiles 的 didSet 会在下一次变更时覆盖写入，不归档就等于静默丢失用户配置。
            let archiveKey = "ai.footprint.profiles.unreadable-\(Int(Date().timeIntervalSince1970))"
            UserDefaults.standard.set(raw, forKey: archiveKey)
            modelMessage = "AI 配置数据无法读取（原始数据已归档）。已回退到默认配置；重新填写并保存后即可继续使用。"
        }

        let providerRaw = UserDefaults.standard.string(forKey: "ai.footprint.provider")
            .flatMap(AIProvider.init(rawValue:)) ?? .openAICompatible
        let legacyEndpoint = UserDefaults.standard.string(forKey: "ai.footprint.endpoint") ?? providerRaw.defaultEndpoint
        let legacyModel = UserDefaults.standard.string(forKey: "ai.footprint.model") ?? providerRaw.defaultModel
        profiles = [AIProfile(name: "默认模型", provider: providerRaw, endpoint: legacyEndpoint, model: legacyModel)]
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "ai.footprint.profiles")
        }
    }

    private func updateActiveProfile(_ transform: (inout AIProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        let old = profiles[index]
        var profile = old
        transform(&profile)

        if profile.provider != old.provider,
           old.endpoint.isEmpty || oldProviderDefaults.contains(old.endpoint) {
            profile.endpoint = profile.provider.defaultEndpoint
        }
        if profile.provider != old.provider,
           old.model.isEmpty || oldProviderDefaults.contains(old.model) {
            profile.model = profile.provider.defaultModel
        }

        profiles[index] = profile
        hasAPIKey = AIKeychain.hasKey(for: selectedProfileID ?? "")
        if profile.provider != old.provider || profile.endpoint != old.endpoint || profile.model != old.model {
            lastRequestRecord = nil
        }
    }

    func addProfile() {
        let base = activeProfile ?? AIProfile(name: "新方案", provider: .openAICompatible)
        let count = profiles.count + 1
        let profile = AIProfile(
            name: "\(base.provider.label) 方案 \(count)",
            provider: base.provider,
            endpoint: base.endpoint,
            model: base.model
        )
        profiles.append(profile)
        selectedProfileID = profile.id
    }

    func duplicateProfile() {
        guard let base = activeProfile else { return }
        let profile = AIProfile(
            name: base.name + " 副本",
            provider: base.provider,
            endpoint: base.endpoint,
            model: base.model
        )
        profiles.append(profile)
        selectedProfileID = profile.id
    }

    func removeProfile() {
        guard profiles.count > 1, let current = activeProfile else { return }
        profiles.removeAll { $0.id == current.id }
        selectedProfileID = profiles.first?.id
        hasAPIKey = selectedProfileID.map { AIKeychain.hasKey(for: $0) } ?? false
    }

    func saveAPIKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let profileID = selectedProfileID, !key.isEmpty else { return }

        do {
            try AIKeychain.saveKey(key, for: profileID)
            hasAPIKey = true
            apiKeyInput = ""
            errorMessage = nil
            lastRequestRecord = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAPIKey() {
        guard let profileID = selectedProfileID else { return }
        AIKeychain.deleteKey(for: profileID)
        hasAPIKey = false
        apiKeyInput = ""
        answer = nil
        lastRequestRecord = nil
    }

    func resetAnswer() {
        answer = nil
        errorMessage = nil
        lastQuestion = nil
    }

    func state(for task: AITask) -> AITaskState? {
        taskStates[task]
    }

    func clearTask(_ task: AITask) {
        taskRequestIDs[task] = UUID()
        taskStates[task] = nil
    }

    func restoreAnalysisResults(startDate: String, endDate: String) {
        // Today can change its date context without recreating the AI store.
        // Clear archived analysis from the previous date before restoring the
        // requested range, otherwise a report can appear under the wrong day.
        for task in AITask.analysisSuite where taskStates[task]?.isArchived == true {
            taskStates[task] = nil
        }

        let saved = AppDatabase.shared.queryAIResults(startDate: startDate, endDate: endDate)
        var seenTasks = Set<String>()

        for result in saved {
            let taskRaw = result.task
            guard seenTasks.insert(taskRaw).inserted,
                  let task = AITask(rawValue: taskRaw),
                  taskStates[task]?.answer == nil,
                  let createdAt = DatabaseTime.date(result.createdAt) else { continue }

            taskStates[task] = AITaskState(
                task: task,
                isLoading: false,
                answer: result.answer,
                error: nil,
                updatedAt: createdAt,
                isArchived: true,
                sourceSummary: result.sourceSummary.isEmpty ? nil : result.sourceSummary,
                model: result.model
            )
        }
    }

    func archivedResult(task: AITask, startDate: String, endDate: String) -> DBAIResult? {
        AppDatabase.shared.queryAIResults(startDate: startDate, endDate: endDate)
            .first { $0.task == task.rawValue }
    }

    private func archiveResult(_ result: InsightResult) {
        AppDatabase.shared.saveAIResult(
            resultKey: result.resultKey,
            startDate: result.startDate,
            endDate: result.endDate,
            task: result.task.rawValue,
            model: result.model,
            answer: result.answer,
            sourceSummary: result.sourceSummary,
            createdAt: result.createdAt,
            isLocal: result.isLocal
        )
    }

    private func setTask(
        _ task: AITask,
        isLoading: Bool = false,
        answer: String? = nil,
        error: String? = nil,
        sourceSummary: String? = nil,
        model: String? = nil,
        isArchived: Bool = false
    ) {
        taskStates[task] = AITaskState(
            task: task,
            isLoading: isLoading,
            answer: answer,
            error: error,
            updatedAt: Date(),
            isArchived: isArchived,
            sourceSummary: sourceSummary,
            model: model
        )
    }

    private func riverTaskKind(for task: AITask) -> RiverTaskKind {
        switch task {
        case .dailyOverview: .dailyOverview
        case .footprintQuestion: .footprintQuestion
        case .insightReading: .insightReading
        case .memorySearch: .memorySearch
        case .riverReading: .riverReading
        case .noteThemes: .noteThemes
        case .analysisWeekly: .weeklyReview
        case .analysisDaily, .analysisMood, .analysisFocus, .analysisHealth, .analysisAction: .analysis
        }
    }

    @discardableResult
    func runTask(
        _ task: AITask,
        system: String,
        prompt: String,
        temperature: Double = 0.25,
        archiveStartDate: String? = nil,
        archiveEndDate: String? = nil,
        sourceSummary: String? = nil,
        evidenceIDs: [UUID] = [],
        contextSnapshotID: UUID? = nil,
        answerTransform: ((String) -> String)? = nil,
        maxTokens: Int? = nil
    ) async -> Bool {
        guard analysisReady, taskStates[task]?.isLoading != true else { return false }

        let requestID = UUID()
        taskRequestIDs[task] = requestID
        setTask(task, isLoading: true)
        do {
            let request = InsightRequest(
                task: task,
                startDate: archiveStartDate,
                endDate: archiveEndDate,
                sourceSummary: sourceSummary ?? "日期范围：\(archiveStartDate ?? "未指定") – \(archiveEndDate ?? "未指定")",
                createdAt: Date()
            )
            let requestModel = model
            let effectivePrompt: String
            if task.isAnalysisSuiteTask {
                effectivePrompt = prompt + """

                最终请统一按以下四段输出，标题必须独占一行：
                **结论**
                **关键依据**
                **建议**
                **边界**
                关键依据尽量引用日期、数值或来源；相关性不能写成因果关系。
                """
            } else {
                effectivePrompt = prompt
            }
            let messages = [
                AIChatMessage(role: "system", content: system),
                AIChatMessage(role: "user", content: effectivePrompt)
            ]
            let rawAnswer = try await sendChat(messages: messages, temperature: temperature, maxTokens: maxTokens)
            guard taskRequestIDs[task] == requestID else { return false }
            let answer = answerTransform?(rawAnswer) ?? rawAnswer
            let result = InsightResult(
                resultKey: request.id,
                startDate: archiveStartDate ?? "",
                endDate: archiveEndDate ?? "",
                task: task,
                model: requestModel,
                answer: answer,
                sourceSummary: request.sourceSummary,
                createdAt: Date(),
                isLocal: false
            )
            if archiveStartDate != nil, archiveEndDate != nil {
                archiveResult(result)
            }
            let savedRun = analysisStore.insertAnalysisRun(AnalysisRun(
                task: riverTaskKind(for: task),
                inputContextReference: contextSnapshotID,
                outputText: answer,
                evidenceIDs: evidenceIDs,
                model: requestModel,
                createdAt: result.createdAt
            ))
            if savedRun {
                NotificationCenter.default.post(name: .riverAnalysisRunDidChange, object: nil)
            } else {
                errorMessage = "分析结果未能写入本地事实库：\(analysisStore.lastError ?? "未知错误")"
            }
            setTask(
                task,
                answer: answer,
                sourceSummary: result.sourceSummary,
                model: result.model,
                isArchived: !result.startDate.isEmpty && !result.endDate.isEmpty
            )
            recordRequest(success: true, message: task.title + "完成")
            return true
        } catch {
            guard taskRequestIDs[task] == requestID else { return false }
            let message = friendlyError(error)
            setTask(task, error: message)
            recordRequest(success: false, message: task.title + "失败：" + message)
            return false
        }
    }

    func needsAutomaticAnalysis(for dateKey: String) -> Bool {
        lastAutomaticAnalysisDate != dateKey
    }

    func markAutomaticAnalysisCompleted(for dateKey: String) {
        lastAutomaticAnalysisDate = dateKey
    }

    func ask(
        question: String,
        range: FusedRangeStats,
        entries: [DiaryEntry],
        scopeLabel: String
    ) async {
        guard isConfigured, !isLoading else { return }

        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        answer = nil
        lastQuestion = trimmedQuestion

        do {
            let context = makeContext(
                range: range,
                entries: entries,
                scopeLabel: scopeLabel
            )
            let response = try await request(question: trimmedQuestion, context: context)
            answer = response
            lastCompletedAt = Date()
            setTask(.footprintQuestion, answer: response)
            recordRequest(success: true, message: "回答完成")
        } catch {
            let message = friendlyError(error)
            errorMessage = message
            setTask(.footprintQuestion, error: message)
            recordRequest(success: false, message: message)
        }

        isLoading = false
    }

    func fetchAvailableModels() async {
        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isLoadingModels else { return }

        if providerRequiresAPIKey && !apiKeyInput.isEmpty {
            saveAPIKey()
        }
        isLoadingModels = true
        modelMessage = nil
        defer { isLoadingModels = false }

        do {
            var request = URLRequest(url: try normalizedModelEndpoint())
            request.timeoutInterval = 20
            try applyHeaders(to: &request)

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
                throw NSError(
                    domain: "RiverDiaryMac.ai",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "获取模型失败：API 返回 \(http.statusCode)。\(body)"]
                )
            }

            let decoded = try JSONDecoder().decode(AIModelListResponse.self, from: data)
            let models = (decoded.data ?? []).compactMap(\.id)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
            availableModels = models

            if models.isEmpty {
                modelMessage = "服务没有返回可用模型列表，可继续手动输入模型名称。"
            } else {
                modelMessage = "已获取 \(models.count) 个可用模型。"
            }
        } catch {
            availableModels = []
            modelMessage = friendlyError(error)
        }
    }

    func testConnection() async {
        if providerRequiresAPIKey && !apiKeyInput.isEmpty {
            saveAPIKey()
        }
        guard isConfigured, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let messages = [
                AIChatMessage(role: "system", content: "Reply with exactly: OK"),
                AIChatMessage(role: "user", content: "Connection test")
            ]
            _ = try await sendChat(messages: messages, temperature: 0)
            answer = "连接成功，API 已可使用。"
            lastQuestion = "连接测试"
            lastCompletedAt = Date()
            recordRequest(success: true, message: "连接成功")
        } catch {
            let message = friendlyError(error)
            errorMessage = message
            answer = nil
            recordRequest(success: false, message: message)
        }
        isLoading = false
    }

    private func recordRequest(success: Bool, message: String) {
        guard let profile = activeProfile else { return }
        let record = AIRequestRecord(
            date: Date(),
            provider: profile.provider.label,
            model: profile.model,
            success: success,
            message: message
        )
        lastRequestRecord = record
        if let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: "ai.footprint.lastRequest")
        }
    }

    private func diaryContext(_ entries: [DiaryEntry], limit: Int = 24) -> String {
        let selected = entries.suffix(limit).map { entry -> String in
            var lines = [
                "date=\(entry.date)",
                "score=\(entry.overall)",
                "stage=\(entry.stateLabel)",
                "overview=\(compactContextText(entry.displayOverview, limit: 360))",
                "thoughts=\(compactContextText((entry.thoughts ?? []).joined(separator: " / "), limit: 420))",
                "memos=\(compactContextText((entry.memos ?? []).joined(separator: " / "), limit: 260))",
                "tags=\((entry.tags ?? []).joined(separator: ","))",
                "screenMinutes=\(entry.screenMinutes ?? -1)",
                "steps=\(entry.health?.steps ?? -1)",
                "sleepMinutes=\(entry.health?.sleepMinutes ?? -1)"
            ]
            if let metrics = entry.metrics {
                lines.append("mood=\(Int(metrics.mood ?? 0));energy=\(Int(metrics.energy ?? 0));focus=\(Int(metrics.focus ?? 0));output=\(Int(metrics.output ?? 0))")
            }
            return "{\(lines.joined(separator: "; "))}"
        }
        return "[\(selected.joined(separator: ",\n"))]"
    }

    private func captureContext(_ captures: [QuickCapture], limit: Int = 20) -> String {
        captures.suffix(limit).map { capture in
            "{date=\(DiaryEntry.dateFormatter.string(from: capture.createdAt)); text=\(compactContextText(capture.text, limit: 260))}"
        }.joined(separator: "\n")
    }

    private func activityContext(_ sessions: [ActivitySession], limit: Int = 20) -> String {
        sessions.suffix(limit).map { session in
            let title = includeTitles ? compactContextText(session.windowTitle ?? "", limit: 120) : ""
            return "{start=\(contextDateTime(session.start)); app=\(session.appName); category=\(session.category); minutes=\(Int(session.duration / 60)); title=\(title)}"
        }.joined(separator: "\n")
    }

    private func compactContextText(_ text: String, limit: Int) -> String {
        let compacted = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(compacted.prefix(limit))
    }

    private func contextDateTime(_ date: Date) -> String {
        Self.contextDateTimeFormatter.string(from: date)
    }

    private func analysisFactSheet(entries: [DiaryEntry], sessions: [ActivitySession]) -> String {
        let overallValues = entries.compactMap { $0.metrics?.overall ?? $0.score }
        let moodValues = entries.compactMap { $0.metrics?.mood ?? $0.score }
        let energyValues = entries.compactMap { $0.metrics?.energy }
        let focusValues = entries.compactMap { $0.metrics?.focus }
        let outputValues = entries.compactMap { $0.metrics?.output }
        let steps = entries.compactMap { $0.health?.steps }
        let sleep = entries.compactMap { $0.health?.resolvedSleepHours }

        let appDurations = Dictionary(grouping: sessions, by: \.appName)
            .mapValues { grouped in grouped.reduce(0) { $0 + $1.duration } }
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { "\($0.key) \(Int(($0.value / 60).rounded())) 分钟" }
            .joined(separator: "、")
        let totalMinutes = Int((sessions.reduce(0) { $0 + $1.duration } / 60).rounded())
        let focusMinutes = Int((sessions.filter { ActivityClassifier.isFocus($0.category) }.reduce(0) { $0 + $1.duration } / 60).rounded())

        var lines = [
            "覆盖：\(entries.count) 天日记，\(sessions.count) 段足迹",
            "实时足迹：总计 \(totalMinutes) 分钟，专注类 \(focusMinutes) 分钟，片段切换约 \(max(0, sessions.count - 1)) 次"
        ]
        if !appDurations.isEmpty { lines.append("主要应用：" + appDurations) }
        appendAverage("整体", values: overallValues, to: &lines)
        appendAverage("心情", values: moodValues, to: &lines)
        appendAverage("精力", values: energyValues, to: &lines)
        appendAverage("专注", values: focusValues, to: &lines)
        appendAverage("产出", values: outputValues, to: &lines)
        if !steps.isEmpty {
            lines.append("步数：\(steps.count) 天有数据，日均 \(Int((Double(steps.reduce(0, +)) / Double(steps.count)).rounded())) 步")
        }
        if !sleep.isEmpty {
            lines.append("睡眠：\(sleep.count) 天有数据，平均 \(String(format: "%.1f", sleep.reduce(0, +) / Double(sleep.count))) 小时")
        }
        let scoredEntries = entries.filter { $0.metrics?.overall != nil || $0.score != nil }
        if let highest = scoredEntries.max(by: { ($0.metrics?.overall ?? $0.score ?? 0) < ($1.metrics?.overall ?? $1.score ?? 0) }),
           let lowest = scoredEntries.min(by: { ($0.metrics?.overall ?? $0.score ?? 0) < ($1.metrics?.overall ?? $1.score ?? 0) }) {
            lines.append("记录高低点：\(highest.date) \(highest.overall) 分；\(lowest.date) \(lowest.overall) 分")
        }
        return lines.map { "- " + $0 }.joined(separator: "\n")
    }

    private func appendAverage(_ label: String, values: [Double], to lines: inout [String]) {
        guard !values.isEmpty else { return }
        let average = values.reduce(0, +) / Double(values.count)
        lines.append("\(label)：\(values.count) 天有评分，平均 \(Int(average.rounded()))")
    }

    func generateDailyOverview(
        entry: DiaryEntry,
        quickCaptures: [QuickCapture],
        activitySessions: [ActivitySession],
        sourceSummary: String? = nil
    ) async {
        let prompt = """
        请根据下面这一天的一手记录，生成一段本日概览。

        要求：
        1. 用简体中文，80-150 字。
        2. 只使用已有证据，不推测没有记录的事实。
        3. 语气自然温柔，不要说教，不要使用 emoji。
        4. 如果证据不足，就明确说证据还不够。
        5. 直接返回正文，不要加“以下是”。

        日记与结构化数据：
        \(diaryContext([entry]))

        快记：
        \(captureContext(quickCaptures))

        macOS 实时片段：
        \(activityContext(activitySessions))
        """
        await runTask(
            .dailyOverview,
            system: "你是河流日记的本日整理同伴。只用用户给定的一手记录做简洁观察；不评判、不补写。回答必须以「我注意到」开头，以「如果你想，可以」结尾。",
            prompt: prompt,
            sourceSummary: sourceSummary
        )
    }

    func searchMemory(query: String, candidateSet: AskCandidateSet, sourceEpisodes: [String: [Episode]] = [:]) async {
        guard analysisReady else { return }

        let cacheKey = memorySearchCacheKey(
            query: query,
            entries: candidateSet.entries,
            quickCaptures: candidateSet.captures,
            memories: candidateSet.memories,
            reflections: candidateSet.reflections,
            manualNotes: candidateSet.manualNotes,
            sourceEpisodes: sourceEpisodes
        )
        if let cached = memorySearchCache[cacheKey] {
            setTask(
                .memorySearch,
                answer: cached,
                sourceSummary: "本机缓存 · 历史内容未变化",
                model: model
            )
            return
        }

        let candidatesForRequest = candidateSet
        let candidates = candidatesForRequest.entries
        let candidateCaptures = candidatesForRequest.captures
        let candidateManualNotes = candidatesForRequest.manualNotes
        let prompt = """
        用户的问题：\(query)

        本地搜索先筛出了以下候选日记。请只基于候选内容回答。
        请严格按下面四段输出，标题必须独占一行，不能改名、合并或省略：
        **结论**
        1-2 句话直接回答，第一句以“我注意到”开头。如果没有找到，明确写“我没有找到匹配的记录”。
        **相关日期**
        最多列出 8 个相关日期，每行格式为“- YYYY-MM-DD：一句说明”。没有相关日期就写“- 无”。
        **证据**
        列出 2-6 条证据，每行格式为“- YYYY-MM-DD · 来源：内容”。来源写日记、快记、活动、时间线标注或每日目标。如果没有证据就写“- 无”。
        **边界**
        用 1-2 句话说明搜索范围和缺失信息；必须说明相关性不代表因果关系，并以“如果你想，可以”结尾。
        不要输出 JSON、表格、标题前言、额外章节或 emoji。只使用给定候选内容，不编造日期和内容。使用简体中文。

        候选日记 JSON：
        \(memorySearchDiaryContext(candidates))

        候选快记：
        \(memorySearchCaptureContext(candidateCaptures))

        候选长期记忆：
        \(candidatesForRequest.memories.map { memory in
            let episodes = sourceEpisodes[memory.id.uuidString] ?? []
            let provenance = episodes.map { "\($0.title)：\($0.summary)" }.joined(separator: "；")
            return "- \(memory.title)：\(memory.body)（置信度 \(memory.confidence)，来源：\(provenance.isEmpty ? "未展开" : provenance)）"
        }.joined(separator: "\n"))

        候选河流信：
        \(candidatesForRequest.reflections.map { "- \($0.title)：\($0.body)（\($0.evidence)）" }.joined(separator: "\n"))

        候选人工标注与每日目标：
        \(AskCandidateContextFormatter.manualNotes(candidateManualNotes))
        """
        let contextSnapshotID = UUID()
        let contextPayload = contextSnapshotPayload(
            query: query,
            entries: candidates,
            captures: candidateCaptures,
            memories: candidatesForRequest.memories,
            reflections: candidatesForRequest.reflections,
            manualNotes: candidateManualNotes,
            sourceEpisodes: sourceEpisodes
        )
        let savedContext = analysisStore.insertContextSnapshot(id: contextSnapshotID, payloadJSON: contextPayload, model: model)
            && analysisStore.contextSnapshotExists(contextSnapshotID)
        await runTask(
            .memorySearch,
            system: "你是河流日记的 AI 搜索同伴。你的输出结构固定为结论、相关日期、证据、边界四段。只引用候选资料，保持温和、准确、可扫描，不把相关性说成因果关系。",
            prompt: prompt,
            temperature: 0.1,
            evidenceIDs: candidatesForRequest.memories.flatMap(\.sourceEpisodeIDs),
            contextSnapshotID: savedContext ? contextSnapshotID : nil,
            answerTransform: AISearchAnswerFormatter.normalize,
            maxTokens: 700
        )

        if let answer = taskStates[.memorySearch]?.answer {
            if memorySearchCache.count >= 20, let oldestKey = memorySearchCache.keys.first {
                memorySearchCache.removeValue(forKey: oldestKey)
            }
            memorySearchCache[cacheKey] = answer
        }
    }

    private func memorySearchDiaryContext(_ entries: [DiaryEntry]) -> String {
        entries.map { entry in
            let fragments = ([entry.displayOverview] + (entry.thoughts ?? []) + (entry.memos ?? []))
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let detail = String(fragments.joined(separator: " / ").prefix(360))
            return "{date=\(entry.date); score=\(entry.overall); tags=\((entry.tags ?? []).joined(separator: ",")); text=\(detail)}"
        }.joined(separator: "\n")
    }

    private func memorySearchCaptureContext(_ captures: [QuickCapture]) -> String {
        captures.map { capture in
            let text = String(capture.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
            return "{date=\(DiaryEntry.dateFormatter.string(from: capture.createdAt)); text=\(text)}"
        }.joined(separator: "\n")
    }

    private func memorySearchCacheKey(
        query: String,
        entries: [DiaryEntry],
        quickCaptures: [QuickCapture],
        memories: [Memory],
        reflections: [MonthlyLetter],
        manualNotes: [MemoryNote],
        sourceEpisodes: [String: [Episode]]
    ) -> String {
        let entryFingerprint = entries.map { "\($0.id):\($0.date):\($0.overall):\($0.displayOverview.hashValue)" }.joined(separator: "|")
        let captureFingerprint = quickCaptures.map { "\($0.id.uuidString):\($0.createdAt.timeIntervalSince1970):\($0.text.hashValue)" }.joined(separator: "|")
        let memoryFingerprint = memories.map { "\($0.id.uuidString):\($0.createdAt.timeIntervalSince1970):\($0.confidence):\($0.body.hashValue)" }.joined(separator: "|")
        let reflectionFingerprint = reflections.map { "\($0.id):\($0.updatedAt.timeIntervalSince1970):\($0.body.hashValue)" }.joined(separator: "|")
        let manualNoteFingerprint = manualNotes.map { "\($0.id):\($0.date):\($0.text.hashValue)" }.joined(separator: "|")
        let episodeFingerprint = sourceEpisodes.values.flatMap { $0 }.map { "\($0.id.uuidString):\($0.startTime.timeIntervalSince1970):\($0.endTime.timeIntervalSince1970)" }.sorted().joined(separator: "|")
        return SHA256Hex.hash(Data("\(query)|\(entryFingerprint)|\(captureFingerprint)|\(memoryFingerprint)|\(reflectionFingerprint)|\(manualNoteFingerprint)|\(episodeFingerprint)".utf8))
    }

    private func contextSnapshotPayload(
        query: String,
        entries: [DiaryEntry],
        captures: [QuickCapture],
        memories: [Memory],
        reflections: [MonthlyLetter],
        manualNotes: [MemoryNote],
        sourceEpisodes: [String: [Episode]]
    ) -> String {
        let payload: [String: Any] = [
            "query": query,
            "diaryIDs": entries.map(\.id),
            "captureIDs": captures.map { $0.id.uuidString },
            "memoryIDs": memories.map { $0.id.uuidString },
            "reflectionIDs": reflections.map(\.id),
            "manualNotes": AskCandidateContextFormatter.manualNoteReferences(manualNotes),
            "episodeIDs": memories.flatMap { sourceEpisodes[$0.id.uuidString, default: []].map { $0.id.uuidString } }
        ]
        guard JSONSerialization.isValidJSONObject(payload), let data = try? JSONSerialization.data(withJSONObject: payload), let value = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return value
    }

    func analyzeInsight(entries: [DiaryEntry]) async {
        let recent = Array(entries.suffix(21))
        let signals = MoodAnalyzer.frequentSignals(entries: recent).prefix(8).map { "\($0.word)：\($0.count) 次" }.joined(separator: "，")
        let prompt = """
        请分析最近日记中的状态线索。

        要求：
        1. 先写一句整体状态。
        2. 再给 2-4 条具体线索，每条引用日期或文字证据。
        3. 最后给一个很小的、可完成的照顾建议。
        4. 不判断好坏，不做医疗建议，不使用 emoji。
        使用简体中文。

        近期日记：
        \(diaryContext(recent, limit: 21))

        本机规则发现的高频词：
        \(signals.isEmpty ? "暂无" : signals)
        """
        await runTask(
            .insightReading,
            system: "你是河流日记的状态阅读同伴。帮助用户看见重复出现的情绪线索；把低落描述为安静或沉重，不用好坏标签。回答必须以「我注意到」开头，以「如果你想，可以」结尾。",
            prompt: prompt
        )
    }

    func analyzeRiver(entries: [DiaryEntry]) async {
        let visible = Array(entries.suffix(30))
        let prompt = """
        这是情绪河流近段数据。请写一段 100-180 字的流动解读。

        要求：
        1. 描述趋势、转折或反复，不要解释成单一原因。
        2. 至少引用两个日期或分数变化。
        3. 语气平静、不审判。
        4. 使用简体中文，直接返回正文。

        近期日记：
        \(diaryContext(visible, limit: 30))
        """
        await runTask(
            .riverReading,
            system: "你是河流日记的情绪河流阅读同伴。关注时间和变化，用冷/暖、活跃/安静描述节律，不给诊断。回答必须以「我注意到」开头，以「如果你想，可以」结尾。",
            prompt: prompt
        )
    }

    func organizeNotes(entries: [DiaryEntry], quickCaptures: [QuickCapture]) async {
        let prompt = """
        请把下面日记片段和快记归纳成可回看的主题。

        要求：
        1. 3-5 个主题，每个主题一行：主题名 —— 涉及日期/内容 —— 一句说明。
        2. 不新增不存在的事项。
        3. 使用简体中文，避免说教。

        日记片段：
        \(diaryContext(entries.suffix(30), limit: 30))

        快记：
        \(captureContext(quickCaptures, limit: 40))
        """
        await runTask(
            .noteThemes,
            system: "你是河流日记的快记与随笔整理同伴。把零散句子归成温和的主题；句子少也没有关系。回答必须以「我注意到」开头，以「如果你想，可以」结尾。",
            prompt: prompt
        )
    }

    // MARK: - AI Analysis Page Tasks

    func runAnalysisBundle(
        entries: [DiaryEntry],
        sessions: [ActivitySession],
        captures: [QuickCapture],
        archiveStartDate: String,
        archiveEndDate: String,
        sourceSummary: String
    ) async {
        let tasks = AITask.analysisSuite
        guard analysisReady, !tasks.contains(where: { taskStates[$0]?.isLoading == true }) else { return }

        let generationID = UUID()
        let requestModel = model
        for task in tasks {
            taskRequestIDs[task] = generationID
            setTask(task, isLoading: true, sourceSummary: sourceSummary, model: requestModel)
        }

        let endDaySessions = sessions.filter {
            DiaryEntry.dateFormatter.string(from: $0.start) == archiveEndDate
        }
        let endDayCaptures = captures.filter {
            DiaryEntry.dateFormatter.string(from: $0.createdAt) == archiveEndDate
        }
        let prompt = """
        请对以下私人生活记录完成一次完整分析，并一次性返回六个部分。六个一级标题必须全部出现、独占一行且顺序固定：

        ## 每日总结
        ## 情绪关联
        ## 专注分析
        ## 健康恢复
        ## 本周规律
        ## 行动建议

        每个部分内部必须使用这四个二级标题：
        **结论**
        **关键依据**
        **建议**
        **边界**

        统一要求：
        1. 使用简体中文，结论先行，每部分控制在 120-220 字。
        2. 关键依据使用项目符号，优先写完整日期、数值、应用或原始记录来源。
        3. 只使用给定数据；缺少数据就明确写出，不用常识补齐。
        4. 相关性不写成因果关系；健康部分不做诊断或医疗建议。
        5. 建议必须具体、可选、能在一天内完成，避免“多休息”“提高效率”这类空话。
        6. “每日总结”只总结结束日 \(archiveEndDate)，不要把整个范围误写成当天。
        7. 不输出 JSON、表格、前言、总结尾声或 emoji。

        分析范围：\(archiveStartDate) – \(archiveEndDate)
        数据摘要：\(sourceSummary)

        本机已计算的确定性统计（优先引用，不要重新猜算）：
        \(analysisFactSheet(entries: entries, sessions: sessions))

        范围内日记、评分与健康数据：
        \(diaryContext(entries, limit: 30))

        范围内 macOS 实时片段：
        \(activityContext(sessions, limit: 60))

        范围内快记：
        \(captureContext(captures, limit: 30))

        结束日实时片段（仅用于每日总结）：
        \(activityContext(endDaySessions, limit: 30))

        结束日快记（仅用于每日总结）：
        \(captureContext(endDayCaptures, limit: 20))
        """

        do {
            let rawAnswer = try await sendChat(
                messages: [
                    AIChatMessage(
                        role: "system",
                        content: "你是河流日记的综合分析引擎。把主观日记、健康数据和真实活动足迹放在同一时间轴上观察。结论必须可追溯，语气温和但不含糊，不评判用户，也不编造缺失信息。"
                    ),
                    AIChatMessage(role: "user", content: prompt)
                ],
                temperature: 0.15,
                maxTokens: 2600
            )
            let parsed = AIAnalysisBundleParser.parse(rawAnswer)

            for task in tasks where taskRequestIDs[task] == generationID {
                guard let answer = parsed[task] else {
                    setTask(
                        task,
                        error: "综合分析没有返回“\(task.title)”部分，请单独重试。",
                        sourceSummary: sourceSummary,
                        model: requestModel
                    )
                    continue
                }

                let request = InsightRequest(
                    task: task,
                    startDate: archiveStartDate,
                    endDate: archiveEndDate,
                    sourceSummary: sourceSummary,
                    createdAt: Date()
                )
                let result = InsightResult(
                    resultKey: request.id,
                    startDate: archiveStartDate,
                    endDate: archiveEndDate,
                    task: task,
                    model: requestModel,
                    answer: answer,
                    sourceSummary: sourceSummary,
                    createdAt: Date(),
                    isLocal: false
                )
                archiveResult(result)
                let savedRun = analysisStore.insertAnalysisRun(AnalysisRun(
                    task: riverTaskKind(for: task),
                    inputContextReference: nil,
                    outputText: answer,
                    evidenceIDs: sessions.map(\.id),
                    model: requestModel,
                    createdAt: result.createdAt
                ))
                if savedRun {
                NotificationCenter.default.post(name: .riverAnalysisRunDidChange, object: nil)
            } else {
                errorMessage = "分析结果未能写入本地事实库：\(analysisStore.lastError ?? "未知错误")"
            }
                setTask(
                    task,
                    answer: answer,
                    sourceSummary: sourceSummary,
                    model: requestModel,
                    isArchived: true
                )
            }

            recordRequest(success: parsed.count == tasks.count, message: "综合分析完成 \(parsed.count)/\(tasks.count) 项")
        } catch {
            let message = friendlyError(error)
            for task in tasks where taskRequestIDs[task] == generationID {
                setTask(task, error: message, sourceSummary: sourceSummary, model: requestModel)
            }
            recordRequest(success: false, message: "综合分析失败：" + message)
        }
    }

    @discardableResult
    func runAnalysisDaily(
        entries: [DiaryEntry],
        sessions: [ActivitySession],
        captures: [QuickCapture],
        archiveStartDate: String? = nil,
        archiveEndDate: String? = nil,
        sourceSummary: String? = nil
    ) async -> Bool {
        let today = entries.last
        let prompt = """
        请根据以下数据，为用户写一段今日总结。

        要求：
        1. 用简体中文，150-250 字。
        2. 按时间段（上午/下午/晚上）叙述，提到具体做了什么。
        3. 结合心情、精力、专注和产出数据，给出一段温暖但不虚假的总结。
        4. 格式：先写「**概览**」一行总结，然后分「**上午**」「**下午**」「**晚上**」三段。
        5. 如果某时间段没有数据就跳过，不要编造。
        6. 不使用 emoji。

        今日评分与指标：
        \(diaryContext([today].compactMap { $0 }))

        macOS 实时片段（按时间排序）：
        \(activityContext(sessions, limit: 30))

        快记：
        \(captureContext(captures))
        """
        return await runTask(
            .analysisDaily,
            system: "你是河流日记的每日分析同伴。根据真实活动数据写出有温度的观察，不做没有依据的推测；把低落描述为安静，不用好坏标签。回答必须以「我注意到」开头，以「如果你想，可以」结尾。",
            prompt: prompt,
            archiveStartDate: archiveStartDate,
            archiveEndDate: archiveEndDate,
            sourceSummary: sourceSummary,
            evidenceIDs: sessions.map(\.id),
            answerTransform: AIAnalysisAnswerFormatter.normalize,
            maxTokens: 900
        )
    }

    func runAnalysisMood(entries: [DiaryEntry], sessions: [ActivitySession], archiveStartDate: String? = nil, archiveEndDate: String? = nil, sourceSummary: String? = nil) async {
        let prompt = """
        请分析用户最近的心情变化和活动之间的关联。

        要求：
        1. 用简体中文。
        2. 格式：
           **核心发现**：用 1-2 句话说清楚最重要的关联。
           **具体线索**：列出 2-4 条具体发现，每条引用数据（如日期、分数、应用名）。
           **模式**：指出 1-2 个反复出现的模式。
        3. 只使用给定数据，不编造。
        4. 如果数据不足，诚实说明。

        最近日记与评分：
        \(diaryContext(entries))

        实时片段：
        \(activityContext(sessions, limit: 30))
        """
        await runTask(
            .analysisMood,
            system: "你是河流日记的情绪分析同伴。从行为数据中发现情绪模式，但只报告有数据支撑的结论；用冷/暖、活跃/安静描述节律，不评判好坏。回答必须以「我注意到」开头，以「如果你想，可以」结尾。",
            prompt: prompt,
            archiveStartDate: archiveStartDate,
            archiveEndDate: archiveEndDate,
            sourceSummary: sourceSummary,
            evidenceIDs: sessions.map(\.id),
            answerTransform: AIAnalysisAnswerFormatter.normalize,
            maxTokens: 900
        )
    }

    func runAnalysisFocus(sessions: [ActivitySession], entries: [DiaryEntry], archiveStartDate: String? = nil, archiveEndDate: String? = nil, sourceSummary: String? = nil) async {
        let focusSessions = sessions.filter { ActivityClassifier.isFocus($0.category) }
        let prompt = """
        请分析用户的专注力和时间管理模式。

        要求：
        1. 用简体中文。
        2. 格式：
           **专注评分**：给出 0-100 的整数评分和一句话解释。
           **深度工作时段**：列出最长的连续专注时间段（应用名 + 时间范围 + 时长）。
           **碎片化**：评估切换频率，指出碎片化最严重的时段。
           **建议**：1-2 条改善专注的具体建议。
        3. 基于实际数据计算，不拍脑袋。

        全部实时片段（按时间排序）：
        \(activityContext(sessions, limit: 50))

        其中专注类片段（工作/学习/创作）：
        \(activityContext(focusSessions, limit: 20))

        日记数据：
        \(diaryContext(entries.suffix(3)))
        """
        await runTask(
            .analysisFocus,
            system: "你是河流日记的专注力分析同伴。通过应用切换模式观察专注质量，只给有依据的建议；不命令、不评价人。回答必须以「我注意到」开头，以「如果你想，可以」结尾。",
            prompt: prompt,
            archiveStartDate: archiveStartDate,
            archiveEndDate: archiveEndDate,
            sourceSummary: sourceSummary,
            answerTransform: AIAnalysisAnswerFormatter.normalize,
            maxTokens: 900
        )
    }

    func runAnalysisHealth(entries: [DiaryEntry], archiveStartDate: String? = nil, archiveEndDate: String? = nil, sourceSummary: String? = nil) async {
        let prompt = """
        请分析用户的健康恢复状况。

        要求：
        1. 用简体中文。
        2. 格式：
           **睡眠**：评价最近几天的睡眠时长和质量。
           **运动**：评价活动量和变化趋势。
           **恢复评分**：给出 0-100 的恢复分数。
           **建议**：1-2 条针对性的恢复建议。
        3. 如果某些数据缺失，在评价中说明，不要跳过不提。

        最近日记与健康数据：
        \(diaryContext(entries.suffix(7)))
        """
        await runTask(
            .analysisHealth,
            system: "你是河流日记的健康分析同伴。关注睡眠、运动与恢复的关系，语气温和，不做医疗建议。回答必须以「我注意到」开头，以「如果你想，可以」结尾。",
            prompt: prompt,
            archiveStartDate: archiveStartDate,
            archiveEndDate: archiveEndDate,
            sourceSummary: sourceSummary,
            answerTransform: AIAnalysisAnswerFormatter.normalize,
            maxTokens: 900
        )
    }

    func runAnalysisWeekly(entries: [DiaryEntry], sessions: [ActivitySession], archiveStartDate: String? = nil, archiveEndDate: String? = nil, sourceSummary: String? = nil) async {
        let prompt = """
        请分析用户过去一周的规律和趋势。

        要求：
        1. 用简体中文。
        2. 格式：
           **整体趋势**：心情/精力/专注/产出的变化方向。
           **最佳一天**：说明是哪天、为什么好（引用数据）。
           **最具挑战的一天**：说明是哪天、遇到了什么。
           **反复出现的规律**：2-3 条在多天里出现的模式。
        3. 只使用给定数据，引用具体日期和数值。

        最近 7 天日记与评分：
        \(diaryContext(entries.suffix(7)))

        最近实时片段：
        \(activityContext(sessions, limit: 40))
        """
        await runTask(
            .analysisWeekly,
            system: "你是河流日记的周报分析同伴。发现跨天规律，语气客观但不冷漠；用节律而不是好坏描述趋势。回答必须以「我注意到」开头，以「如果你想，可以」结尾。",
            prompt: prompt,
            archiveStartDate: archiveStartDate,
            archiveEndDate: archiveEndDate,
            sourceSummary: sourceSummary,
            evidenceIDs: sessions.map(\.id),
            answerTransform: AIAnalysisAnswerFormatter.normalize,
            maxTokens: 900
        )
    }

    func runAnalysisAction(entries: [DiaryEntry], sessions: [ActivitySession], archiveStartDate: String? = nil, archiveEndDate: String? = nil, sourceSummary: String? = nil) async {
        let prompt = """
        请基于用户的数据，给出 3 条明天可以行动的具体建议。

        要求：
        1. 用简体中文。
        2. 格式：
           **建议 1**（优先级：高）：做什么 + 为什么（引用数据）。
           **建议 2**（优先级：中）：做什么 + 为什么。
           **建议 3**（优先级：低）：做什么 + 为什么。
        3. 每条建议必须具体可执行，不要说「多休息」「多运动」这种空话。
        4. 语气鼓励但不命令。

        最近日记与评分：
        \(diaryContext(entries.suffix(5)))

        最近实时片段：
        \(activityContext(sessions, limit: 30))
        """
        await runTask(
            .analysisAction,
            system: "你是河流日记的行动建议同伴。基于数据给出具体、可执行的建议，不说空话；建议是可选的陪伴，不是命令。回答必须以「我注意到」开头，以「如果你想，可以」结尾。",
            prompt: prompt,
            archiveStartDate: archiveStartDate,
            archiveEndDate: archiveEndDate,
            sourceSummary: sourceSummary,
            answerTransform: AIAnalysisAnswerFormatter.normalize,
            maxTokens: 900
        )
    }

    private func makeContext(
        range: FusedRangeStats,
        entries: [DiaryEntry],
        scopeLabel: String
    ) -> AIAnalysisContext {
        // Imported data can contain duplicate dates. Keep the latest entry rather
        // than crashing while preparing an AI request.
        let entriesByDate = entries.reduce(into: [String: DiaryEntry]()) { result, entry in
            result[entry.date] = entry
        }

        let daily = range.dayStats.map { day in
            let entry = entriesByDate[day.dateKey]
            return AIDayContext(
                date: day.dateKey,
                screenMinutes: Int(day.pipelineTotal / 60),
                liveMinutes: Int(day.liveTotal / 60),
                focusMinutes: Int(day.focusTotal / 60),
                steps: day.health?.steps ?? 0,
                mood: entry?.mood,
                energy: entry?.energy,
                focusScore: entry?.focus,
                outputScore: entry?.output,
                topApps: day.appUsage.prefix(3).map { "\($0.name) \(Int($0.duration / 60))m" }
            )
        }

        let sessions: [AISessionContext]?
        if includeTitles {
            let recentSessions = range.liveSessions.suffix(25)
            sessions = recentSessions.map { session in
                AISessionContext(
                    app: session.appName,
                    category: session.category,
                    start: session.start.formatted(date: .omitted, time: .shortened),
                    minutes: Int(session.duration / 60),
                    title: session.windowTitle
                )
            }
        } else {
            sessions = nil
        }

        return AIAnalysisContext(
            scope: scopeLabel,
            days: range.days,
            pipelineTotalMinutes: Int(range.pipelineTotal / 60),
            liveTotalMinutes: Int(range.liveTotal / 60),
            focusTotalMinutes: Int(range.focusTotal / 60),
            fragmentation: range.fragmentation,
            confidence: range.confidence,
            apps: range.appUsage.map {
                AIAppUsageContext(
                    name: $0.name,
                    minutes: Int($0.duration / 60),
                    category: $0.category,
                    source: $0.source.rawValue
                )
            },
            categories: range.categoryUsage.map {
                AIAppUsageContext(
                    name: $0.name,
                    minutes: Int($0.duration / 60),
                    category: $0.name,
                    source: $0.source.rawValue
                )
            },
            browse: range.browseUsage.map {
                AIBrowseContext(site: $0.site, visits: $0.visits)
            },
            timeline: range.timeline.map {
                AIHourContext(
                    hour: $0.hour,
                    minutes: Int($0.duration / 60),
                    primaryCategory: $0.primaryCategory
                )
            },
            health: AIHealthContext(
                steps: range.healthSteps,
                distanceKM: range.healthDistance,
                activeEnergyKcal: range.healthEnergy
            ),
            daily: daily,
            recentSessions: sessions
        )
    }

    private func request(question: String, context: AIAnalysisContext) async throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let contextData = try encoder.encode(context)
        let contextText = String(data: contextData, encoding: .utf8) ?? "{}"

        let messages = [
            AIChatMessage(
                role: "system",
                content: """
                你是河流日记的足迹分析助手。请使用简体中文。只基于用户提供的数据回答，不编造。
                项目管道是每日总量的权威来源；macOS 实时数据用于时间分布和专注片段。
                不要把两个来源的时长重复相加。相关趋势不代表因果。回答要直接、温柔、可读，避免说教。
                """
            ),
            AIChatMessage(
                role: "user",
                content: "问题：\(question)\n\n足迹数据 JSON：\n\(contextText)"
            )
        ]

        return try await sendChat(messages: messages, temperature: 0.2)
    }

    private func sendChat(
        messages: [AIChatMessage],
        temperature: Double,
        maxTokens: Int? = nil
    ) async throws -> String {
        let payload = AIChatRequest(
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: messages,
            temperature: temperature,
            stream: false,
            maxTokens: maxTokens
        )

        var request = URLRequest(url: try normalizedEndpoint())
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        try applyHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if let decoded = try? JSONDecoder().decode(AIChatResponse.self, from: data),
               let message = decoded.error?.message {
                throw NSError(
                    domain: "RiverDiaryMac.ai",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }

            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw NSError(
                domain: "RiverDiaryMac.ai",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API 返回 \(http.statusCode)。\(body)"]
            )
        }

        let decoded = try JSONDecoder().decode(AIChatResponse.self, from: data)
        if let message = decoded.error?.message {
            throw NSError(
                domain: "RiverDiaryMac.ai",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        guard let content = decoded.choices?.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw NSError(
                domain: "RiverDiaryMac.ai",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "API 没有返回内容"]
            )
        }

        return content
    }

    private func applyHeaders(to request: inout URLRequest) throws {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if provider == .openRouter {
            request.setValue("River Diary", forHTTPHeaderField: "X-Title")
            request.setValue("https://riverdiary.local", forHTTPHeaderField: "HTTP-Referer")
        }
        if providerRequiresAPIKey {
            guard let key = currentAPIKey(), !key.isEmpty else {
                throw NSError(
                    domain: "RiverDiaryMac.ai",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "API Key 不可读取，请重新粘贴并保存。"]
                )
            }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private func currentAPIKey() -> String? {
        if !apiKeyInput.isEmpty { return apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let profileID = selectedProfileID else { return nil }
        return AIKeychain.readKey(for: profileID)
    }

    private func normalizedEndpoint() throws -> URL {
        try normalizedURL(suffix: "chat/completions", invalidMessage: "API 地址无效")
    }

    private func normalizedModelEndpoint() throws -> URL {
        try normalizedURL(suffix: "models", invalidMessage: "API 地址无效")
    }

    private func normalizedURL(suffix: String, invalidMessage: String) throws -> URL {
        var text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") {
            text.removeLast()
        }

        let lowercased = text.lowercased()
        if !lowercased.hasPrefix("https://") && !lowercased.hasPrefix("http://") {
            let scheme = (provider == .ollama || provider == .lmStudio) ? "http://" : "https://"
            text = scheme + text
        }

        if suffix == "models" {
            if text.hasSuffix("/chat/completions") {
                text.removeLast("chat/completions".count)
                while text.hasSuffix("/") { text.removeLast() }
            }

            if !text.hasSuffix("/models") {
                if text.hasSuffix("/v1") || text.hasSuffix("/v4") || text.hasSuffix("/compatible-mode") {
                    text += "/models"
                } else if text.contains("/v1/") || text.contains("/v4/") || text.contains("/compatible-mode/") {
                    text += "/models"
                } else {
                    text += "/v1/models"
                }
            }
        } else if !text.hasSuffix("/chat/completions") {
            if text.hasSuffix("/v1") {
                text += "/chat/completions"
            } else if !text.contains("/v1/") && !text.contains("/chat/") {
                text += "/v1/chat/completions"
            }
        }

        guard let url = URL(string: text), url.scheme == "https" || url.scheme == "http" else {
            throw NSError(
                domain: "RiverDiaryMac.ai",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: invalidMessage]
            )
        }

        return url
    }

    private func friendlyError(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.contains("cancelled") { return "请求已取消。" }
        if message.contains("Authentication Fails") || message.contains("invalid_api_key") || message.contains("Unauthorized") {
            return "API Key 无效，或还没有保存成功。"
        }
        if message.contains("404") || message.contains("Not Found") {
            return "接口地址不正确。请确认使用服务商文档里的 OpenAI 兼容 Chat Completions 地址。"
        }
        if message.contains("model") && (message.contains("not found") || message.contains("does not exist")) {
            return "模型名称不存在或当前 Key 无权使用该模型。"
        }
        if message.contains("seems to be offline") || message.contains("network") {
            return "网络连接失败，请检查网络或 API 地址。"
        }
        return message
    }
}
