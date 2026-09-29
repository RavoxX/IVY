import Foundation
import IVYCore

/// One-shot text generation with the local model, without tools: clipboard rewrites,
/// synonyms and other small transformations that run inside a tool. Uses the writing model
/// when one is chosen (Settings ▸ AI), else the main model.
final class LLMTextService: Sendable {
    private let main: MLXLLMService
    private let writer: @Sendable () -> MLXLLMService?
    private let settings: SettingsStore

    init(main: MLXLLMService, writer: @escaping @Sendable () -> MLXLLMService?, settings: SettingsStore) {
        self.main = main
        self.writer = writer
        self.settings = settings
    }

    private var llm: MLXLLMService { writer() ?? main }
    var isAvailable: Bool { llm.isAvailable }

    /// `onText` receives the cumulative text while it streams.
    func complete(system: String, user: String, maxTokens: Int, temperature: Double = 0.2,
                  onText: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let llm = self.llm
        guard llm.isAvailable else { throw LocalModelError.modelNotInstalled(llm.descriptor.displayName) }
        var options = settings.generationOptions
        options.maxTokens = maxTokens
        options.temperature = temperature
        let buffer = TextAccumulator()
        let raw = try await llm.generate(messages: [.system(system), .user(user)], tools: [], options: options) { token in
            guard let onText else { return }
            onText(ToolCallParser.stripThinking(buffer.append(token)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ToolCallParser.stripThinking(raw)
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Thread-safe string builder for streamed tokens.
private final class TextAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ token: String) -> String {
        lock.withLock {
            text += token
            return text
        }
    }
}
