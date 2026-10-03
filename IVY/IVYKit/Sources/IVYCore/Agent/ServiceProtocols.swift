import Foundation

// MARK: - Chat messages

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant, tool }

    public var role: Role
    public var content: String
    public var toolCalls: [ToolCall]
    public var toolName: String?
    /// Native provider blocks retained in memory for tool IDs and reasoning signatures.
    public var providerResponse: ProviderResponse?

    public init(role: Role, content: String, toolCalls: [ToolCall] = [], toolName: String? = nil,
                providerResponse: ProviderResponse? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolName = toolName
        self.providerResponse = providerResponse
    }

    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text) }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, content: text) }
    public static func assistant(_ text: String, toolCalls: [ToolCall] = [],
                                 providerResponse: ProviderResponse? = nil) -> ChatMessage {
        ChatMessage(role: .assistant, content: text, toolCalls: toolCalls, providerResponse: providerResponse)
    }
    public static func tool(_ name: String, _ payload: String) -> ChatMessage {
        ChatMessage(role: .tool, content: payload, toolName: name)
    }

    /// Hugging Face chat-template message format (consumed by Qwen3's template).
    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = ["role": .string(role.rawValue), "content": .string(content)]
        if !toolCalls.isEmpty {
            object["tool_calls"] = .array(toolCalls.map { call in
                ["type": "function", "function": ["name": .string(call.name), "arguments": .object(call.arguments)]]
            })
        }
        if let toolName { object["name"] = .string(toolName) }
        return .object(object)
    }
}

// MARK: - LLM

public struct GenerationOptions: Sendable, Equatable {
    public var maxTokens: Int
    public var temperature: Double
    public var topP: Double
    public var contextLength: Int

    public init(maxTokens: Int = 320, temperature: Double = 0.3, topP: Double = 0.9, contextLength: Int = 8192) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.contextLength = contextLength
    }
}

public enum LocalModelError: LocalizedError, Sendable, Equatable {
    case runtimeNotInstalled
    case modelNotInstalled(String)
    case engineFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .runtimeNotInstalled: return "IVY's local AI runtime isn't installed. Open IVY Settings to set it up."
        case .modelNotInstalled(let name): return "\(name) isn't installed. Open IVY Settings to download it."
        case .engineFailed(let message): return message
        case .cancelled: return "Cancelled."
        }
    }
}

/// Language model abstraction shared by local MLX and explicitly selected cloud providers.
public protocol LocalLLMService: AnyObject, Sendable {
    /// The runtime/model or cloud credentials are configured.
    var isAvailable: Bool { get }
    var availabilityError: any Error { get }
    var supportsWarmUp: Bool { get }
    /// Pins provider, model and credentials for an entire agent request.
    func forRequest() -> any LocalLLMService
    var isLoaded: Bool { get async }
    func loadModel() async throws
    func unloadModel() async
    /// Generates a reply; `onToken` receives streamed text fragments.
    func generate(messages: [ChatMessage], tools: [JSONValue], options: GenerationOptions,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> String
    func cancelGeneration() async
    func generateResponse(messages: [ChatMessage], tools: [JSONValue], options: GenerationOptions,
                          onToken: @escaping @Sendable (String) -> Void) async throws -> ToolCallParser.Output
}

public extension LocalLLMService {
    var availabilityError: any Error { LocalModelError.modelNotInstalled(ModelCatalog.defaultLLM.displayName) }
    var supportsWarmUp: Bool { true }
    func forRequest() -> any LocalLLMService { self }
    func generateResponse(messages: [ChatMessage], tools: [JSONValue], options: GenerationOptions,
                          onToken: @escaping @Sendable (String) -> Void) async throws -> ToolCallParser.Output {
        let raw = try await generate(messages: messages, tools: tools, options: options, onToken: onToken)
        return ToolCallParser.parse(raw)
    }
}

// MARK: - Speech

public protocol SpeechRecognitionService: AnyObject, Sendable {
    var isAvailable: Bool { get }
    func prepare() async throws
    /// Transcribes 16 kHz mono float samples.
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String
    func unload() async
}

public protocol TTSService: AnyObject, Sendable {
    var isAvailable: Bool { get }
    func prepare() async throws
    /// Synthesizes and plays `text`; returns when playback finished or was stopped.
    func speak(_ text: String) async throws
    func stop() async
    func unload() async
}
