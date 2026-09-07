import Foundation
import LocalAuthentication
import Security

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case openAICompatible
    case deepseek
    case moonshot
    case openRouter
    case alibabaCloud
    case zhipuAI
    case xAI
    case groq
    case mistral
    case siliconFlow
    case ollama
    case lmStudio
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAICompatible: "OpenAI 兼容"
        case .deepseek: "DeepSeek"
        case .moonshot: "Moonshot"
        case .openRouter: "OpenRouter"
        case .alibabaCloud: "阿里云百炼"
        case .zhipuAI: "智谱 AI"
        case .xAI: "xAI"
        case .groq: "Groq"
        case .mistral: "Mistral"
        case .siliconFlow: "SiliconFlow"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .custom: "自定义"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .openAICompatible: "https://api.openai.com/v1/chat/completions"
        case .deepseek: "https://api.deepseek.com/chat/completions"
        case .moonshot: "https://api.moonshot.cn/v1/chat/completions"
        case .openRouter: "https://openrouter.ai/api/v1/chat/completions"
        case .alibabaCloud: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        case .zhipuAI: "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        case .xAI: "https://api.x.ai/v1/chat/completions"
        case .groq: "https://api.groq.com/openai/v1/chat/completions"
        case .mistral: "https://api.mistral.ai/v1/chat/completions"
        case .siliconFlow: "https://api.siliconflow.cn/v1/chat/completions"
        case .ollama: "http://localhost:11434/v1/chat/completions"
        case .lmStudio: "http://localhost:1234/v1/chat/completions"
        case .custom: ""
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .ollama, .lmStudio: false
        default: true
        }
    }

    var defaultModel: String {
        switch self {
        case .openAICompatible: "gpt-4o-mini"
        case .deepseek: "deepseek-chat"
        case .moonshot: "moonshot-v1-8k"
        case .openRouter: "openai/gpt-4o-mini"
        case .alibabaCloud: "qwen-plus"
        case .zhipuAI: "glm-4-flash"
        case .xAI: "grok-3-mini"
        case .groq: "llama-3.3-70b-versatile"
        case .mistral: "mistral-small-latest"
        case .siliconFlow: "deepseek-ai/DeepSeek-V3"
        case .ollama: "llama3.2"
        case .lmStudio: "local-model"
        case .custom: ""
        }
    }
}

enum AIKeychainError: LocalizedError {
    case invalidStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStatus(let status): "钥匙串保存失败（\(status)）"
        }
    }
}

enum AIKeychain {
    private static let service = "RiverDiaryMac.ai"
    private static let legacyAccount = "footprint-api-key"

    private static func account(for profileID: String) -> String {
        "footprint-api-key-\(profileID)"
    }

    private static func keychainQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func hasKey(for profileID: String) -> Bool {
        var query = keychainQuery(account: account(for: profileID))
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess { return true }

        var legacyQuery = keychainQuery(account: legacyAccount)
        legacyQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        if SecItemCopyMatching(legacyQuery as CFDictionary, nil) == errSecSuccess { return true }
        return AISecureKeyStore.hasKey(for: profileID)
    }

    static func readKey(for profileID: String) -> String? {
        var item: CFTypeRef?
        var query = keychainQuery(account: account(for: profileID))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var status = SecItemCopyMatching(query as CFDictionary, &item)

        if status != errSecSuccess {
            query = keychainQuery(account: legacyAccount)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(query as CFDictionary, &item)
        }

        if status == errSecSuccess, let data = item as? Data,
           let key = String(data: data, encoding: .utf8), !key.isEmpty {
            return key
        }
        return AISecureKeyStore.readKey(for: profileID)
    }

    static func saveKey(_ value: String, for profileID: String) throws {
        try AISecureKeyStore.saveKey(value, for: profileID)
        let keyData = Data(value.utf8)
        var query = keychainQuery(account: account(for: profileID))
        let update: [String: Any] = [kSecValueData as String: keyData]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw AIKeychainError.invalidStatus(updateStatus)
        }

        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AIKeychainError.invalidStatus(addStatus)
        }
    }

    static func deleteKey(for profileID: String) {
        AISecureKeyStore.deleteKey(for: profileID)
        SecItemDelete(keychainQuery(account: account(for: profileID)) as CFDictionary)
        SecItemDelete(keychainQuery(account: legacyAccount) as CFDictionary)
    }
}

/// 加密文件作为 API Key 的备用存储。应用已用同一机制保护日记状态。
enum AISecureKeyStore {
    private static var keyFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("RiverDiaryMac", isDirectory: true).appendingPathComponent("Keys", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("api-keys.bin")
    }

    private static func loadKeys() -> [String: String] {
        guard let url = keyFileURL,
              let raw = try? Data(contentsOf: url),
              let decrypted = try? StateEncryption.decrypt(raw),
              let decoded = try? JSONDecoder().decode([String: String].self, from: decrypted) else {
            return [:]
        }
        return decoded
    }

    private static func persist(_ keys: [String: String]) throws {
        guard let url = keyFileURL else { return }
        let plaintext = try JSONEncoder().encode(keys)
        try StateEncryption.encrypt(plaintext).write(to: url, options: .atomic)
    }

    static func hasKey(for profileID: String) -> Bool {
        !(loadKeys()[profileID] ?? "").isEmpty
    }

    static func readKey(for profileID: String) -> String? {
        let key = loadKeys()[profileID] ?? ""
        return key.isEmpty ? nil : key
    }

    static func saveKey(_ value: String, for profileID: String) throws {
        var keys = loadKeys()
        keys[profileID] = value
        try persist(keys)
    }

    static func deleteKey(for profileID: String) {
        var keys = loadKeys()
        keys.removeValue(forKey: profileID)
        try? persist(keys)
    }
}

private struct AIChatMessage: Codable {
    var role: String
    var content: String
}

private struct AIChatRequest: Codable {
    var model: String
    var messages: [AIChatMessage]
    var temperature: Double
    var stream: Bool
}

private struct AIModelListResponse: Codable {
    struct Model: Codable {
        var id: String?
    }

    var `data`: [Model]?
}

private struct AIChatResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            var content: String?
        }

        var message: Message?
    }

    struct APIError: Codable {
        var message: String?
    }

    var choices: [Choice]?
    var error: APIError?
}

private struct AIAppUsageContext: Codable {
    var name: String
    var minutes: Int
    var category: String
    var source: String
}

private struct AIBrowseContext: Codable {
    var site: String
    var visits: Int
}

private struct AIHourContext: Codable {
    var hour: Int
    var minutes: Int
    var primaryCategory: String
}

private struct AIHealthContext: Codable {
    var steps: Int
    var distanceKM: Double
    var activeEnergyKcal: Double
}

private struct AIDayContext: Codable {
    var date: String
    var screenMinutes: Int
    var liveMinutes: Int
    var focusMinutes: Int
    var steps: Int
    var mood: Int?
    var energy: Int?
    var focusScore: Int?
    var outputScore: Int?
    var topApps: [String]
}

private struct AISessionContext: Codable {
    var app: String
    var category: String
    var start: String
    var minutes: Int
    var title: String?
}

private struct AIAnalysisContext: Codable {
    var scope: String
    var days: Int
    var pipelineTotalMinutes: Int
    var liveTotalMinutes: Int
    var focusTotalMinutes: Int
    var fragmentation: Int
    var confidence: Int
    var apps: [AIAppUsageContext]
    var categories: [AIAppUsageContext]
    var browse: [AIBrowseContext]
    var timeline: [AIHourContext]
    var health: AIHealthContext
    var daily: [AIDayContext]
    var recentSessions: [AISessionContext]?
}

private struct AIRequestPayload {
    var question: String
    var context: AIAnalysisContext
}

enum AITask: String {
    case dailyOverview
    case footprintQuestion
    case insightReading
    case memorySearch
    case riverReading
    case noteThemes
    case analysisDaily
    case analysisMood
    case analysisFocus
    case analysisHealth
    case analysisWeekly
    case analysisAction

    var title: String {
        switch self {
        case .dailyOverview: "AI 本日整理"
        case .footprintQuestion: "AI 足迹问答"
        case .insightReading: "AI 状态洞察"
        case .memorySearch: "AI 回忆搜索"
        case .riverReading: "AI 情绪河流"
        case .noteThemes: "AI 快记归纳"
        case .analysisDaily: "每日总结"
        case .analysisMood: "情绪关联"
        case .analysisFocus: "专注分析"
        case .analysisHealth: "健康恢复"
        case .analysisWeekly: "本周规律"
        case .analysisAction: "行动建议"
        }
    }

    var analysisIcon: String {
        switch self {
        case .analysisDaily: "sun.max.fill"
        case .analysisMood: "heart.circle.fill"
        case .analysisFocus: "scope"
        case .analysisHealth: "leaf.fill"
        case .analysisWeekly: "calendar.badge.clock"
        case .analysisAction: "lightbulb.fill"
        default: "sparkles"
        }
    }

    var analysisColor: String {
        switch self {
        case .analysisDaily: "#7C5CFC"
        case .analysisMood: "#F06292"
        case .analysisFocus: "#42A5F5"
        case .analysisHealth: "#66BB6A"
        case .analysisWeekly: "#FFA726"
        case .analysisAction: "#26C6DA"
        default: "#7787FF"
        }
    }

    var analysisSubtitle: String {
        switch self {
        case .analysisDaily: "把今天的数据变成一段有温度的叙述"
        case .analysisMood: "找出情绪变化和活动之间的关联"
        case .analysisFocus: "分析专注模式和碎片化程度"
        case .analysisHealth: "睡眠、运动与恢复的关系"
        case .analysisWeekly: "过去一周的规律和趋势"
        case .analysisAction: "基于数据给出明日建议"
        default: ""
        }
    }
}

struct AITaskState: Identifiable {
    var id: String { task.rawValue }
    var task: AITask
    var isLoading = false
    var answer: String?
    var error: String?
    var updatedAt: Date?
    var isArchived = false
}

struct AIProfile: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var provider: AIProvider
    var endpoint: String
    var model: String

    init(
        id: String = UUID().uuidString,
        name: String,
        provider: AIProvider,
        endpoint: String? = nil,
        model: String? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.endpoint = endpoint ?? provider.defaultEndpoint
        self.model = model ?? provider.defaultModel
    }
}

struct AIRequestRecord: Codable {
    var date: Date
    var provider: String
    var model: String
    var success: Bool
    var message: String
}

@MainActor
final class AIAssistantStore: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "ai.footprint.enabled") }
    }

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
    @Published private(set) var taskStates: [AITask: AITaskState] = [:]

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
        isEnabled && isConfigured
    }

    var requestSummary: String? {
        guard let record = lastRequestRecord else { return nil }
        let time = record.date.formatted(date: .omitted, time: .shortened)
        return "\(time) · \(record.model) · \(record.success ? "成功" : "失败")"
    }

    init() {
        isEnabled = UserDefaults.standard.object(forKey: "ai.footprint.enabled") == nil
            ? false
            : UserDefaults.standard.bool(forKey: "ai.footprint.enabled")
        includeTitles = UserDefaults.standard.bool(forKey: "ai.footprint.includeTitles")
        loadProfiles()
        selectedProfileID = UserDefaults.standard.string(forKey: "ai.footprint.selectedProfile")
            .flatMap { id in profiles.contains { $0.id == id } ? id : nil }
            ?? profiles.first?.id
        hasAPIKey = selectedProfileID.map { AIKeychain.hasKey(for: $0) } ?? false
        lastRequestRecord = UserDefaults.standard.data(forKey: "ai.footprint.lastRequest")
            .flatMap { try? JSONDecoder().decode(AIRequestRecord.self, from: $0) }
    }

    private func loadProfiles() {
        if let raw = UserDefaults.standard.data(forKey: "ai.footprint.profiles"),
           var decoded = try? JSONDecoder().decode([AIProfile].self, from: raw),
           !decoded.isEmpty {
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
        taskStates[task] = nil
    }

    func restoreAnalysisResults(startDate: String, endDate: String) {
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
                isArchived: true
            )
        }
    }

    private func archiveResult(_ task: AITask, answer: String, startDate: String?, endDate: String?) {
        guard let profile = activeProfile,
              let start = startDate,
              let end = endDate else { return }

        AppDatabase.shared.saveAIResult(
            resultKey: "\(start)|\(end)|\(task.rawValue)",
            startDate: start,
            endDate: end,
            task: task.rawValue,
            model: profile.model,
            answer: answer
        )
    }

    private func setTask(
        _ task: AITask,
        isLoading: Bool = false,
        answer: String? = nil,
        error: String? = nil
    ) {
        taskStates[task] = AITaskState(
            task: task,
            isLoading: isLoading,
            answer: answer,
            error: error,
            updatedAt: Date()
        )
    }

    func runTask(
        _ task: AITask,
        system: String,
        prompt: String,
        temperature: Double = 0.25,
        archiveStartDate: String? = nil,
        archiveEndDate: String? = nil
    ) async {
        guard analysisReady, taskStates[task]?.isLoading != true else { return }

        setTask(task, isLoading: true)
        do {
            let messages = [
                AIChatMessage(role: "system", content: system),
                AIChatMessage(role: "user", content: prompt)
            ]
            let answer = try await sendChat(messages: messages, temperature: temperature)
            setTask(task, answer: answer)
            archiveResult(task, answer: answer, startDate: archiveStartDate, endDate: archiveEndDate)
            taskStates[task]?.isArchived = archiveStartDate != nil && archiveEndDate != nil
            recordRequest(success: true, message: task.title + "完成")
        } catch {
            let message = friendlyError(error)
            setTask(task, error: message)
            recordRequest(success: false, message: task.title + "失败：" + message)
        }
    }

    func ask(
        question: String,
        range: FusedRangeStats,
        entries: [DiaryEntry],
        scopeLabel: String
    ) async {
        guard isEnabled, isConfigured, !isLoading else { return }

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
                "overview=\(entry.displayOverview)",
                "thoughts=\((entry.thoughts ?? []).joined(separator: " / "))",
                "memos=\((entry.memos ?? []).joined(separator: " / "))",
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
            "{date=\(DiaryEntry.dateFormatter.string(from: capture.createdAt)); text=\(capture.text)}"
        }.joined(separator: "\n")
    }

    private func activityContext(_ sessions: [ActivitySession], limit: Int = 20) -> String {
        sessions.suffix(limit).map { session in
            "{start=\(session.start.formatted(date: .omitted, time: .shortened)); app=\(session.appName); category=\(session.category); minutes=\(Int(session.duration / 60)); title=\(session.windowTitle ?? "")}"
        }.joined(separator: "\n")
    }

    func generateDailyOverview(
        entry: DiaryEntry,
        quickCaptures: [QuickCapture],
        activitySessions: [ActivitySession]
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
            prompt: prompt
        )
    }

    func searchMemory(query: String, entries: [DiaryEntry], quickCaptures: [QuickCapture]) async {
        let local = MemorySearchEngine.search(query, entries: entries, quickCaptures: quickCaptures)
        let candidates = Array(Set(local.entries + entries.suffix(40))).sorted { $0.date < $1.date }
        let prompt = """
        用户的问题：\(query)

        本地搜索先筛出了以下候选日记。请只基于候选内容回答。
        要求：先给一句直接摘要；再给出 2-4 条证据，每条带日期；如果候选中没有答案，就明说没有找到。
        不要编造日期或内容。使用简体中文。

        候选日记 JSON：
        \(diaryContext(candidates, limit: 40))

        候选快记：
        \(captureContext(quickCaptures))
        """
        await runTask(
            .memorySearch,
            system: "你是河流日记的回忆搜索同伴。找出有日期依据的内容，安静地呈现即可；不评判、不补写。回答必须以「我注意到」开头，以「如果你想，可以」结尾。",
            prompt: prompt
        )
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

    func runAnalysisDaily(
        entries: [DiaryEntry],
        sessions: [ActivitySession],
        captures: [QuickCapture],
        archiveStartDate: String? = nil,
        archiveEndDate: String? = nil
    ) async {
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
        await runTask(
            .analysisDaily,
            system: "你是河流日记的每日分析同伴。根据真实活动数据写出有温度的观察，不做没有依据的推测；把低落描述为安静，不用好坏标签。回答必须以「我注意到」开头，以「如果你想，可以」结尾。",
            prompt: prompt,
            archiveStartDate: archiveStartDate,
            archiveEndDate: archiveEndDate
        )
    }

    func runAnalysisMood(entries: [DiaryEntry], sessions: [ActivitySession], archiveStartDate: String? = nil, archiveEndDate: String? = nil) async {
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
            archiveEndDate: archiveEndDate
        )
    }

    func runAnalysisFocus(sessions: [ActivitySession], entries: [DiaryEntry], archiveStartDate: String? = nil, archiveEndDate: String? = nil) async {
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
            archiveEndDate: archiveEndDate
        )
    }

    func runAnalysisHealth(entries: [DiaryEntry], archiveStartDate: String? = nil, archiveEndDate: String? = nil) async {
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
            archiveEndDate: archiveEndDate
        )
    }

    func runAnalysisWeekly(entries: [DiaryEntry], sessions: [ActivitySession], archiveStartDate: String? = nil, archiveEndDate: String? = nil) async {
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
            archiveEndDate: archiveEndDate
        )
    }

    func runAnalysisAction(entries: [DiaryEntry], sessions: [ActivitySession], archiveStartDate: String? = nil, archiveEndDate: String? = nil) async {
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
            archiveEndDate: archiveEndDate
        )
    }

    private func makeContext(
        range: FusedRangeStats,
        entries: [DiaryEntry],
        scopeLabel: String
    ) -> AIAnalysisContext {
        let entriesByDate = Dictionary(uniqueKeysWithValues: entries.map { ($0.date, $0) })

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

    private func sendChat(messages: [AIChatMessage], temperature: Double) async throws -> String {
        let payload = AIChatRequest(
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: messages,
            temperature: temperature,
            stream: false
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
