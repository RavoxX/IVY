import Foundation

/// Direct HTTPS calls to the selected provider. No local runtime or third-party SDK is needed.
/// Text streams immediately; native tool arguments are buffered and validated after completion.
public final class CloudLLMService: LocalLLMService, @unchecked Sendable {
    private let configuration: CloudModelConfiguration
    private let usage: @Sendable (AIUsage) async -> Void
    private let session: URLSession

    public init(configuration: CloudModelConfiguration, session: URLSession = URLSession(configuration: .ephemeral),
                usage: @escaping @Sendable (AIUsage) async -> Void = { _ in }) {
        self.usage = usage
        self.configuration = configuration
        self.session = session
    }

    public var isAvailable: Bool { configuration.validationError == nil }
    public var availabilityError: any Error { configuration.validationError ?? .invalidResponse }
    public var supportsWarmUp: Bool { false }
    public var isLoaded: Bool { get async { isAvailable } }
    public func loadModel() async throws {
        if let error = configuration.validationError { throw error }
    }
    public func unloadModel() async { await cancelGeneration() }
    public func cancelGeneration() async {
        // The app supplies a dedicated session, shared only by IVY's cloud model requests.
        for task in await session.allTasks { task.cancel() }
    }

    public func generate(messages: [ChatMessage], tools: [JSONValue], options: GenerationOptions,
                         onToken: @escaping @Sendable (String) -> Void) async throws -> String {
        let output = try await generateResponse(messages: messages, tools: tools, options: options, onToken: onToken)
        return output.text
    }

    public func generateResponse(messages: [ChatMessage], tools: [JSONValue], options: GenerationOptions,
                                 onToken: @escaping @Sendable (String) -> Void) async throws -> ToolCallParser.Output {
        try Task.checkCancellation()
        try await loadModel()
        let started = Date()
        var request = try CloudProviderCodec.request(configuration, messages: messages, tools: tools, options: options)
        if configuration.provider == .gemini {
            request.url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(configuration.model):streamGenerateContent?alt=sse")!
        } else if let body = request.httpBody, var object = (try? JSONDecoder().decode(JSONValue.self, from: body))?.objectValue {
            object["stream"] = true
            request.httpBody = try JSONEncoder().encode(JSONValue.object(object))
        }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let value: JSONValue
        var streamed = false
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw CloudModelError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw CloudModelError.http(configuration.provider, http.statusCode) }
            if response.mimeType == "text/event-stream" {
                streamed = true
                var decoder = CloudStreamDecoder(provider: configuration.provider)
                var frames = SSEFrameDecoder(limit: 10_000_000)
                for try await byte in bytes {
                    try Task.checkCancellation()
                    if let payload = try frames.receive(byte), payload != "[DONE]" {
                        guard let event = JSONValue.parse(payload) else { throw CloudModelError.invalidResponse }
                        try decoder.receive(event, onText: onToken)
                    }
                }
                value = try decoder.finish()
            } else {
                var data = Data()
                for try await byte in bytes {
                    guard data.count < 10_000_000 else { throw CloudModelError.invalidResponse }
                    data.append(byte)
                }
                guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw CloudModelError.invalidResponse }
                value = decoded
            }
        } catch {
            await usage(.cloud(nil, provider: configuration.provider, model: configuration.model,
                               seconds: Date().timeIntervalSince(started), succeeded: false))
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        let output: ToolCallParser.Output
        do {
            output = try CloudProviderCodec.response(value, configuration: configuration)
        } catch {
            await usage(.cloud(value, provider: configuration.provider, model: configuration.model,
                               seconds: Date().timeIntervalSince(started), succeeded: false))
            throw error
        }
        await usage(.cloud(value, provider: configuration.provider, model: configuration.model,
                           seconds: Date().timeIntervalSince(started), succeeded: true))
        if !streamed, output.toolCalls.isEmpty, !output.text.isEmpty { onToken(output.text) }
        return output
    }
}
