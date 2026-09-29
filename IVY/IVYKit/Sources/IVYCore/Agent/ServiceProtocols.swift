import Foundation

// MARK: - Chat messages

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant, tool }

    public var role: Role
    public var content: String
    public var toolCalls: [ToolCall]
    public var toolName: String?

    public init(role: Role, content: String, toolCalls: [ToolCall] = [], toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolName = toolName
    }

    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text) }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, content: text) }
    public static func assistant(_ text: String, toolCalls: [ToolCall] = []) -> ChatMessage {
        ChatMessage(role: .assistant, content: text, toolCalls: toolCalls)
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

/// Local language model abstraction. The default implementation (`MLXLLMService`) runs
/// Qwen3-4B through MLX-LM, but any backend that speaks chat messages can be plugged in.
public protocol LocalLLMService: AnyObject, Sendable {
    /// Weights and runtime are present on disk.
    var isAvailable: Bool { get }
    var isLoaded: Bool { get async }
    func loadModel() async throws
    func unloadModel() async
    /// Generates a reply; `onToken` receives streamed text fragments.
    func generate(messages: [ChatMessage], tools: [JSONValue], options: GenerationOptions,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> String
    func cancelGeneration() async
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
