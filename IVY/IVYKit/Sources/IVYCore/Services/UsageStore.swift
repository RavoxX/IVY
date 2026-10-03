import Foundation

/// Contains counts and timing only. Prompts, responses, keys and tool arguments are never recorded.
public struct AIUsage: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let provider: AIProvider
    public let model: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cachedTokens: Int?
    public let seconds: Double
    public let succeeded: Bool
    public init(provider: AIProvider, model: String, inputTokens: Int? = nil, outputTokens: Int? = nil,
                cachedTokens: Int? = nil, seconds: Double, succeeded: Bool) {
        id = UUID(); date = Date(); self.provider = provider; self.model = model
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.cachedTokens = cachedTokens
        self.seconds = max(0, seconds); self.succeeded = succeeded
    }
    public static func cloud(_ value: JSONValue?, provider: AIProvider, model: String,
                             seconds: Double, succeeded: Bool) -> AIUsage {
        let usage = value?[provider == .gemini ? "usageMetadata" : "usage"]
        func count(_ key: String) -> Int? {
            safeCount(usage?[key]?.doubleValue)
        }
        func safeCount(_ number: Double?) -> Int? {
            guard let number, number >= 0, let count = Int(exactly: number), count <= 1_000_000_000 else { return nil }
            return count
        }
        let input = count(provider == .gemini ? "promptTokenCount" : "input_tokens")
        let output = count(provider == .gemini ? "candidatesTokenCount" : "output_tokens")
        let cached = provider == .openAI ? safeCount(usage?["input_tokens_details"]?["cached_tokens"]?.doubleValue)
            : count(provider == .gemini ? "cachedContentTokenCount" : "cache_read_input_tokens")
        // Gemini's thinking tokens are output tokens too.
        return AIUsage(provider: provider, model: model, inputTokens: input,
                       outputTokens: output.map { $0 + (provider == .gemini ? count("thoughtsTokenCount") ?? 0 : 0) },
                       cachedTokens: cached, seconds: seconds, succeeded: succeeded)
    }
}

public actor UsageStore {
    private let fileURL: URL
    private var records: [AIUsage]?
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func all() -> [AIUsage] {
        if records == nil {
            records = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([AIUsage].self, from: $0) } ?? []
        }
        return records ?? []
    }
    public func append(_ usage: AIUsage) {
        var values = all(); values.insert(usage, at: 0)
        records = Array(values.prefix(20_000))
        persist()
    }
    public func clear() { records = []; persist() }
    private func persist() {
        guard let data = try? JSONEncoder().encode(records ?? []) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
