import Foundation
import IVYCore

/// One-shot text generation with the selected model, without tools: clipboard rewrites,
/// synonyms and other small transformations that run inside a tool. Uses the writing model
/// when one is chosen (Settings ▸ AI), else the main model.
final class LLMTextService: Sendable {
    private let main: ConfiguredLLMService
    private let settings: SettingsStore

    init(main: ConfiguredLLMService, settings: SettingsStore) {
        self.main = main
        self.settings = settings
    }

    private var llm: any LocalLLMService { model(for: .writing) }
    private func model(for task: AITask) -> any LocalLLMService {
        main.forTask(task)
    }
    var isAvailable: Bool { llm.isAvailable }
    func isAvailable(for task: AITask) -> Bool { model(for: task).isAvailable }

    /// `onText` receives the cumulative text while it streams.
    func complete(system: String, user: String, task: AITask = .writing, maxTokens: Int, temperature: Double = 0.2,
                  onText: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let llm = model(for: task)
        guard llm.isAvailable else { throw llm.availabilityError }
        var options = settings.generationOptions
        options.contextLength = llm.supportsWarmUp ? max(2048, settings.int(.contextLength)) : 128_000
        options.maxTokens = llm.supportsWarmUp ? maxTokens : max(maxTokens, settings.int(.cloudMaxResponseTokens))
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
