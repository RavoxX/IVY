import Foundation

/// Resolves Settings for each request, with no fallback or traffic to an unselected provider.
public final class ConfiguredLLMService: LocalLLMService, @unchecked Sendable {
    private let local: any LocalLLMService
    private let settings: SettingsStore
    private let apiKey: @Sendable (AIProvider) -> String
    private let session: URLSession

    public init(local: any LocalLLMService, settings: SettingsStore,
                session: URLSession = URLSession(configuration: .ephemeral),
                apiKey: @escaping @Sendable (AIProvider) -> String) {
        self.local = local
        self.settings = settings
        self.session = session
        self.apiKey = apiKey
    }

    public func forRequest() -> any LocalLLMService {
        let provider = settings.aiProvider
        guard provider != .local else { return local }
        return CloudLLMService(configuration: .init(provider: provider, model: settings.cloudModel(for: provider),
                                                    apiKey: apiKey(provider)), session: session)
    }
    public var isAvailable: Bool { forRequest().isAvailable }
    public var availabilityError: any Error { forRequest().availabilityError }
    public var supportsWarmUp: Bool { settings.aiProvider == .local }
    public var isLoaded: Bool { get async { await forRequest().isLoaded } }
    public func loadModel() async throws { try await forRequest().loadModel() }
    public func unloadModel() async {
        await local.unloadModel()
        await cancelGeneration()
    }
    public func cancelGeneration() async {
        await local.cancelGeneration()
        for task in await session.allTasks { task.cancel() }
    }
    public func generate(messages: [ChatMessage], tools: [JSONValue], options: GenerationOptions,
                         onToken: @escaping @Sendable (String) -> Void) async throws -> String {
        try await forRequest().generate(messages: messages, tools: tools, options: options, onToken: onToken)
    }
    public func generateResponse(messages: [ChatMessage], tools: [JSONValue], options: GenerationOptions,
                                 onToken: @escaping @Sendable (String) -> Void) async throws -> ToolCallParser.Output {
        try await forRequest().generateResponse(messages: messages, tools: tools, options: options, onToken: onToken)
    }
}
