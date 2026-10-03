import Foundation

public enum CloudModelDiscovery {
    /// User-triggered only. Lists model IDs without including credentials in the URL.
    public static func models(provider: AIProvider, apiKey: String, session: URLSession = URLSession(configuration: .ephemeral)) async throws -> [String] {
        guard !apiKey.isEmpty, !apiKey.contains(where: { $0.isNewline }) else { throw CloudModelError.missingAPIKey(provider) }
        let url: URL
        switch provider {
        case .gemini: url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!
        case .claude: url = URL(string: "https://api.anthropic.com/v1/models?limit=100")!
        case .openAI: url = URL(string: "https://api.openai.com/v1/models")!
        case .local: return ModelCatalog.llms.map(\.id)
        }
        var request = URLRequest(url: url)
        switch provider {
        case .gemini: request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .claude:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI: request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .local: break
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudModelError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw CloudModelError.http(provider, http.statusCode) }
        guard data.count < 2_000_000, let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw CloudModelError.invalidResponse }
        let values = value[provider == .gemini ? "models" : "data"]?.arrayValue ?? []
        return values.compactMap { item in
            if provider == .gemini {
                guard item["supportedGenerationMethods"]?.arrayValue?.contains("generateContent") == true else { return nil }
                return item["name"]?.stringValue.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
            }
            return item["id"]?.stringValue
        }.filter { CloudModelConfiguration(provider: provider, model: $0, apiKey: "configured").validationError == nil }.sorted()
    }
}
