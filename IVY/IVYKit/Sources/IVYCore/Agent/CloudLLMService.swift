import Foundation

/// Direct HTTPS calls to the selected provider. No local runtime or third-party SDK is needed.
/// Responses are buffered so incomplete tool arguments can never execute.
public final class CloudLLMService: LocalLLMService, @unchecked Sendable {
    private let configuration: CloudModelConfiguration
    private let session: URLSession

    public init(configuration: CloudModelConfiguration, session: URLSession = URLSession(configuration: .ephemeral)) {
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
        let request = try CloudProviderCodec.request(configuration, messages: messages, tools: tools, options: options)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw CloudModelError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // Never display/log response bodies: providers may echo private inputs or credentials.
            throw CloudModelError.http(configuration.provider, http.statusCode)
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw CloudModelError.invalidResponse
        }
        let output = try CloudProviderCodec.response(value, configuration: configuration)
        if output.toolCalls.isEmpty, !output.text.isEmpty { onToken(output.text) }
        return output
    }
}
