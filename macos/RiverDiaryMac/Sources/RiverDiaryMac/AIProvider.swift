import Foundation

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

