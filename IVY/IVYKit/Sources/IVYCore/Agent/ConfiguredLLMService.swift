import Foundation

/// Resolves Settings for each request, with no fallback or traffic to an unselected provider.
public final class ConfiguredLLMService: LocalLLMService, @unchecked Sendable {
    private let local: any LocalLLMService
    private let settings: SettingsStore
    private let apiKey: @Sendable (AIProvider) -> String
    private let localModel: @Sendable (String) -> (any LocalLLMService)?
    private let usage: @Sendable (AIUsage) async -> Void
    private let session: URLSession

    public init(local: any LocalLLMService, settings: SettingsStore,
                session: URLSession = URLSession(configuration: .ephemeral),
                localModel: @escaping @Sendable (String) -> (any LocalLLMService)? = { _ in nil },
                usage: @escaping @Sendable (AIUsage) async -> Void = { _ in },
                apiKey: @escaping @Sendable (AIProvider) -> String) {
        self.localModel = localModel
        self.usage = usage
        self.local = local
        self.settings = settings
        self.session = session
        self.apiKey = apiKey
    }

    public func forRequest() -> any LocalLLMService { forTask(.commands) }
    public func forTask(_ task: AITask) -> any LocalLLMService {
        let choice = settings.modelChoice(for: task)
        if choice.provider == .local {
            if choice.model == settings.string(.llmModelID) { return local }
            return localModel(choice.model) ?? local
        }
        return CloudLLMService(configuration: .init(provider: choice.provider, model: choice.model,
                                                    apiKey: apiKey(choice.provider)), session: session, usage: usage)
    }
    public var isAvailable: Bool { forRequest().isAvailable }
    public var availabilityError: any Error { forRequest().availabilityError }
    public var supportsWarmUp: Bool { settings.modelChoice(for: .commands).provider == .local }
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
