import Foundation
import IVYCore

/// One-shot text generation with the local model, without tools: clipboard rewrites,
/// synonyms and other small transformations that run inside a tool.
final class LLMTextService: Sendable {
    private let llm: MLXLLMService
    private let settings: SettingsStore

    init(llm: MLXLLMService, settings: SettingsStore) {
        self.llm = llm
        self.settings = settings
    }

    var isAvailable: Bool { llm.isAvailable }

    func complete(system: String, user: String, maxTokens: Int, temperature: Double = 0.2) async throws -> String {
        guard llm.isAvailable else { throw LocalModelError.modelNotInstalled(llm.descriptor.displayName) }
        var options = settings.generationOptions
        options.maxTokens = maxTokens
        options.temperature = temperature
        let raw = try await llm.generate(messages: [.system(system), .user(user)], tools: [], options: options) { _ in }
        return ToolCallParser.stripThinking(raw)
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
