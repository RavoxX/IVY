import Foundation

public enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case local, gemini, claude, openAI
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .local: return "Local (MLX)"
        case .gemini: return "Google Gemini"
        case .claude: return "Anthropic Claude"
        case .openAI: return "OpenAI"
        }
    }

    public var modelSetting: SettingsKey? {
        switch self {
        case .local: return nil
        case .gemini: return .geminiModel
        case .claude: return .claudeModel
        case .openAI: return .openAIModel
        }
    }

    public var defaultModel: String { suggestedModels.first ?? "" }
    public var suggestedModels: [String] {
        switch self {
        case .local: return []
        case .gemini: return ["gemini-3.5-flash-lite", "gemini-3.8-flash"]
        case .claude: return ["claude-haiku-4-5", "claude-sonnet-5-5", "claude-opus-5-5"]
        case .openAI: return ["gpt-4.1-mini", "gpt-4.1", "gpt-6-astra"]
        }
    }

    public var keychainAccount: String { "ai.apiKey.\(rawValue)" }
    public var apiKeyURL: URL {
        switch self {
        case .gemini: return URL(string: "https://aistudio.google.com/api-keys")!
        case .claude: return URL(string: "https://platform.claude.com/settings/keys")!
        case .openAI, .local: return URL(string: "https://platform.openai.com/api-keys")!
        }
    }
}

/// Kept only in the active conversation, never in history or UserDefaults.
public struct ProviderResponse: Sendable, Equatable {
    public let provider: AIProvider
    public let model: String
    public let blocks: [JSONValue]

    public init(provider: AIProvider, model: String, blocks: [JSONValue]) {
        self.provider = provider
        self.model = model
        self.blocks = blocks
    }
}

public enum CloudModelError: LocalizedError, Sendable, Equatable {
    case missingAPIKey(AIProvider)
    case invalidModel
    case http(AIProvider, Int)
    case invalidResponse
    case incompleteResponse
    case blockedResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Add your \(provider.displayName) API key in Settings ▸ AI."
        case .invalidModel: return "Enter a valid model ID in Settings ▸ AI (letters, numbers, dots, underscores or hyphens)."
        case .http(let provider, let status):
            switch status {
            case 401, 403: return "\(provider.displayName) rejected this request. Check your API key and model access in Settings ▸ AI."
            case 404: return "\(provider.displayName) couldn't find this model. Check the model ID in Settings ▸ AI."
            case 429: return "\(provider.displayName)'s quota or rate limit was reached. Check your API billing or try again later."
            default: return "\(provider.displayName) request failed (HTTP \(status)). Check the model ID or try again later."
            }
        case .invalidResponse: return "The AI provider returned an unreadable response. Try again."
        case .incompleteResponse: return "The AI response exceeded its token limit. Increase the maximum response length in Settings ▸ AI."
        case .blockedResponse: return "The AI provider declined this request."
        }
    }
}

public struct CloudModelConfiguration: Sendable {
    public let provider: AIProvider
    public let model: String
    public let apiKey: String

    public init(provider: AIProvider, model: String, apiKey: String) {
        self.provider = provider
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var validationError: CloudModelError? {
        guard provider != .local, !model.isEmpty, model.count <= 150,
              model.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || [45, 46, 95].contains($0) }) else { return .invalidModel }
        guard !apiKey.isEmpty, !apiKey.contains(where: { $0.isNewline }) else { return .missingAPIKey(provider) }
        return nil
    }
}
