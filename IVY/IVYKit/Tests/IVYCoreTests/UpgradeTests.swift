import Foundation
import Testing
@testable import IVYCore

private final class UpgradeFailingModel: LocalLLMService, @unchecked Sendable {
    var isAvailable: Bool { true }
    var isLoaded: Bool { get async { true } }
    func loadModel() async throws {}
    func unloadModel() async {}
    func cancelGeneration() async {}
    func generate(messages: [ChatMessage], tools: [JSONValue], options: GenerationOptions, onToken: @escaping @Sendable (String) -> Void) async throws -> String {
        throw CloudModelError.http(.gemini, 400)
    }
}
private final class RetryTool: IVYTool, @unchecked Sendable {
    let name: String
    let description = "test"
    let displayName = "test"
    let baseRisk = RiskLevel.high
    let parameters: [ToolParameter] = []
    let lock = NSLock()
    private var count = 0
    private var fails = true
    init(name: String) { self.name = name }
    var calls: Int { lock.withLock { count } }
    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        lock.withLock { count += 1; defer { fails = false }; return fails ? .failure("Temporary failure") : ToolResult(summary: "Succeeded") }
    }
}
private func outcome(_ stream: AsyncStream<AgentEvent>) async -> AgentOutcome? {
    var final: AgentOutcome?
    for await event in stream { if case .finished(let result) = event { final = result } }
    return final
}

@Suite("IVY workspace upgrade")
struct UpgradeTests {
    @Test("Dashboard settings preserve order, discard invalid and duplicate widgets, and permit an empty dashboard")
    func dashboard() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.set("mail,battery,unknown,mail,reminders", for: .dashboardWidgets)
        #expect(store.dashboardWidgets == [.mail, .battery, .reminders])
        store.set("", for: .dashboardWidgets); #expect(store.dashboardWidgets.isEmpty)
        #expect(store.bool(.dashboardMusic))
    }
    @Test("Stable version comparison uses numeric components and rejects prereleases and malformed tags")
    func versions() throws {
        #expect(try #require(ReleaseVersion("v1.10.0")) > #require(ReleaseVersion("1.9")))
        #expect(ReleaseVersion("2.0") == ReleaseVersion("2.0.0"))
        for bad in ["1", "1..2", "1.2-beta", "../../1.2", "1.2.3.4.5", "-1.2", "1.∞"] { #expect(ReleaseVersion(bad) == nil) }
    }
    @Test("MCP endpoints don't allow credentials, insecure remote URLs or secret query strings")
    func endpoints() {
        for good in ["https://mcp.notion.com/mcp", "http://127.0.0.1:3456/mcp", "http://localhost:3000/mcp"] { #expect(MCPURL.validate(URL(string: good)!)) }
        for bad in ["http://example.com/mcp", "https://user:password@example.com/mcp", "https://example.com/mcp?key=secret", "file:///tmp/server", "https://example.com/mcp#secret"] { #expect(!MCPURL.validate(URL(string: bad)!)) }
    }
    @Test("Unknown token counts stay unknown, and Gemini thinking counts as output")
    func tokenCounts() {
        let usage = AIUsage.cloud(["usageMetadata": ["promptTokenCount": 10, "candidatesTokenCount": 4, "thoughtsTokenCount": 3, "cachedContentTokenCount": 2]],
                                  provider: .gemini, model: "test", seconds: 1.2, succeeded: true)
        #expect(usage.inputTokens == 10); #expect(usage.outputTokens == 7); #expect(usage.cachedTokens == 2)
        let unknown = AIUsage.cloud(nil, provider: .openAI, model: "test", seconds: 0, succeeded: false)
        #expect(unknown.inputTokens == nil); #expect(unknown.outputTokens == nil)
    }
    @Test("Usage persists counts without prompt or credential fields and clearing persists")
    func usageStorage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage.json")
        let store = UsageStore(fileURL: file)
        await store.append(.init(provider: .claude, model: "haiku", inputTokens: 10, outputTokens: 3, seconds: 0.4, succeeded: true))
        let reopened = UsageStore(fileURL: file)
        #expect(await reopened.all().count == 1)
        let text = try String(contentsOf: file)
        #expect(!text.contains("prompt")); #expect(!text.contains("apiKey")); #expect(!text.contains("response"))
        await store.clear()
        #expect(await UsageStore(fileURL: file).all().isEmpty)
    }
    @Test("Incomplete streamed tool calls never produce a response")
    func truncatedStream() throws {
        var stream = CloudStreamDecoder(provider: .claude)
        try stream.receive(["type": "message_start", "message": ["usage": ["input_tokens": 5]]]) { _ in }
        try stream.receive(["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "a", "name": "dangerous", "input": [:]]]) { _ in }
        try stream.receive(["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": "{\"value\":"]]) { _ in }
        #expect(throws: CloudModelError.incompleteResponse) { try stream.finish() }
    }
    @Test("Claude streaming retains full arguments, signature and cumulative usage")
    func claudeStream() throws {
        var stream = CloudStreamDecoder(provider: .claude)
        try stream.receive(["type": "message_start", "message": ["usage": ["input_tokens": 12], "role": "assistant"]]) { _ in }
        try stream.receive(["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "a", "name": "lookup", "input": [:]]]) { _ in }
        try stream.receive(["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": "{\"value\":"]]) { _ in }
        try stream.receive(["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": "\"real\"}"]]) { _ in }
        try stream.receive(["type": "content_block_stop", "index": 0]) { _ in }
        try stream.receive(["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 8]]) { _ in }
        try stream.receive(["type": "message_stop"]) { _ in }
        let value = try stream.finish()
        let output = try CloudProviderCodec.response(value, configuration: .init(provider: .claude, model: "test", apiKey: "test"))
        #expect(output.toolCalls.first?.arguments["value"] == "real")
        #expect(value["usage"]?["input_tokens"] == 12); #expect(value["usage"]?["output_tokens"] == 8)
    }
    @Test("Gemini streaming preserves native thought signatures, calls and completion")
    func geminiStream() throws {
        var stream = CloudStreamDecoder(provider: .gemini)
        try stream.receive(["candidates": [["content": ["parts": [["text": "Reasoning", "thought": true]]]]]]) { _ in }
        try stream.receive(["candidates": [["content": ["parts": [["thoughtSignature": "sig", "functionCall": ["name": "lookup", "args": ["value": "real"]]]]], "finishReason": "STOP"]],
                            "usageMetadata": ["promptTokenCount": 10, "candidatesTokenCount": 5]]) { _ in }
        let output = try CloudProviderCodec.response(stream.finish(), configuration: .init(provider: .gemini, model: "test", apiKey: "test"))
        #expect(output.text.isEmpty); #expect(output.toolCalls.count == 1)
        #expect(output.providerResponse?.blocks.last?["thoughtSignature"] == "sig")
    }
    @Test("OpenAI streaming requires a final completed response and doesn't treat preview text as tool arguments")
    func openAIStream() throws {
        var stream = CloudStreamDecoder(provider: .openAI)
        try stream.receive(["type": "response.output_text.delta", "delta": "Hello"]) { _ in }
        #expect(throws: CloudModelError.incompleteResponse) { try stream.finish() }
        try stream.receive(["type": "response.completed", "response": ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "Hello"]]]]]]) { _ in }
        #expect(try CloudProviderCodec.response(stream.finish(), configuration: .init(provider: .openAI, model: "test", apiKey: "test")).text == "Hello")
    }
    @Test("Failed web answer passes expose Gemini errors instead of reporting the search as an answer")
    func searchFailure() async {
        let search = RecordingTool(name: ToolName.webSearch, terminal: false, summary: "Found five results.", requiresModelAnswer: true)
        let agent = AgentService(llm: UpgradeFailingModel(), registry: ToolRegistry(tools: [search]), router: CommandRouter(resolveApp: { _ in nil }), confirm: { _ in true })
        let result = await outcome(agent.run("Search the internet for how tall the Eiffel Tower is"))
        #expect(result?.status == .failure)
        #expect(result?.text.contains("AI answer failed") == true)
        #expect(result?.text.contains("Google Gemini") == true)
        #expect(search.calls.count == 1)
    }
    @Test("Retry runs failed actions alone and confirms high-risk actions again")
    func retry() async {
        let successful = RecordingTool(name: "success", summary: "Succeeded")
        let failed = RetryTool(name: "fail")
        let llm = FakeLLM(responses: [#"<tool_call>{"name":"success","arguments":{}}</tool_call><tool_call>{"name":"fail","arguments":{}}</tool_call>"#, "One action failed."])
        let approvals = ApprovalCounter()
        let agent = AgentService(llm: llm, registry: ToolRegistry(tools: [successful, failed]), router: CommandRouter(resolveApp: { _ in nil }),
            fastRoutingEnabled: { false }, confirm: { _ in await approvals.increment(); return true })
        _ = await outcome(agent.run("Do both things"))
        #expect(successful.calls.count == 1); #expect(failed.calls == 1)
        let retried = await outcome(agent.retryFailed())
        #expect(retried?.status == .success); #expect(failed.calls == 2); #expect(successful.calls.count == 1)
        #expect(await approvals.count == 2)
    }
    @Test("Follow-up model context keeps actual tool results and clearing removes them")
    func references() async throws {
        let tool = RecordingTool(name: ToolName.remindersList, summary: "Reminder ID abc: Call Alex")
        let llm = FakeLLM(responses: ["Which reminder?"])
        let agent = AgentService(llm: llm, registry: ToolRegistry(tools: [tool]), router: CommandRouter(resolveApp: { _ in nil }), confirm: { _ in true })
        _ = await outcome(agent.run("What's on my to-do list today?"))
        _ = await outcome(agent.run("Tell me about the second one"))
        #expect(llm.received.last?.contains { $0.content.contains("Reminder ID abc") } == true)
        await agent.resetConversation()
        _ = await outcome(agent.run("Tell me about the second one"))
        #expect(llm.received.last?.contains { $0.content.contains("Reminder ID abc") } == false)
    }
    @Test("Routines validate bounds, persist and reject empty steps")
    func routines() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("routines.json")
        let routine = AssistantRoutine(name: "Morning", commands: ["Show today's reminders", "Show calendar"])
        let store = RoutineStore(fileURL: file); try await store.save(routine)
        #expect(await RoutineStore(fileURL: file).all() == [routine])
        #expect(!AssistantRoutine(name: "Too much", commands: Array(repeating: "Step", count: 9)).isValid)
        #expect(!AssistantRoutine(name: "Empty", commands: [" "]).isValid)
        try await store.remove(routine.id); #expect(await store.all().isEmpty)
    }
    @Test("Disconnection removes tool schemas and untrusted annotations cannot lower high risk")
    func registryRemoval() {
        let remote = RecordingTool(name: "mcp_remote", risk: .high)
        let local = RecordingTool(name: "local")
        let registry = ToolRegistry(tools: [remote, local])
        #expect(SecurityPolicy().requiresConfirmation(tool: remote, arguments: [:]))
        registry.remove(names: ["mcp_remote"])
        #expect(registry.tool(named: "mcp_remote") == nil); #expect(registry.allTools.count == 1)
        #expect(registry.schemas.first?["function"]?["name"] == "local")
    }
}
private actor ApprovalCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
