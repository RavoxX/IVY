import Foundation
import Testing
@testable import IVYCore

// MARK: - Fakes

final class FakeLLM: LocalLLMService, @unchecked Sendable {
    var responses: [String]
    private(set) var received: [[ChatMessage]] = []
    private(set) var loadCount = 0
    private var loaded = false
    let lock = NSLock()

    init(responses: [String]) { self.responses = responses }

    var isAvailable: Bool { true }
    var isLoaded: Bool { get async { lock.withLock { loaded } } }
    func loadModel() async throws { lock.withLock { loaded = true; loadCount += 1 } }
    func unloadModel() async { lock.withLock { loaded = false } }
    func cancelGeneration() async {}

    func generate(messages: [ChatMessage], tools: [JSONValue], options: GenerationOptions,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> String {
        let reply: String = lock.withLock {
            received.append(messages)
            return responses.isEmpty ? "Done." : responses.removeFirst()
        }
        onToken(reply)
        return reply
    }
}

final class RecordingTool: IVYTool, @unchecked Sendable {
    let name: String
    let description = "test tool"
    let parameters: [ToolParameter] = [ToolParameter("value", .string, "any")]
    let displayName = "Test"
    let baseRisk: RiskLevel
    let isTerminal: Bool
    let requiresModelAnswer: Bool
    let summary: String
    private let lock = NSLock()
    private var _calls: [[String: JSONValue]] = []
    var calls: [[String: JSONValue]] { lock.withLock { _calls } }

    init(name: String, risk: RiskLevel = .low, terminal: Bool = true, summary: String = "Done.",
         requiresModelAnswer: Bool = false) {
        self.name = name
        self.baseRisk = risk
        self.isTerminal = terminal
        self.requiresModelAnswer = requiresModelAnswer
        self.summary = summary
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        lock.withLock { _calls.append(arguments) }
        return ToolResult(summary: summary, card: .list(title: name, rows: []))
    }
}

private func collect(_ stream: AsyncStream<AgentEvent>) async -> (outcome: AgentOutcome?, error: String?, events: [AgentEvent]) {
    var events: [AgentEvent] = []
    var outcome: AgentOutcome?
    var error: String?
    for await event in stream {
        events.append(event)
        if case .finished(let o) = event { outcome = o }
        if case .failed(let e) = event { error = e }
    }
    return (outcome, error, events)
}

private let noApps = CommandRouter(resolveApp: { _ in nil })

// MARK: - Tests

@Suite("AgentService tool routing")
struct AgentServiceTests {
    @Test("Fast-routed commands skip the model")
    func fastRouteSkipsModel() async {
        let llm = FakeLLM(responses: [])
        let tool = RecordingTool(name: ToolName.musicControl, summary: "Paused.")
        let agent = AgentService(llm: llm, registry: ToolRegistry(tools: [tool]), router: noApps, confirm: { _ in true })
        let result = await collect(agent.run("Pause the music."))
        #expect(result.outcome?.text == "Paused.")
        #expect(tool.calls == [["action": "pause"]])
        #expect(llm.received.isEmpty)
        #expect(llm.loadCount == 0)
    }

    @Test("Fast-routed web searches are answered by the model, not the tool's status line")
    func fastRoutedSearchGetsModelAnswer() async throws {
        let llm = FakeLLM(responses: ["- OpenWeather: free weather data\n- NewsAPI: headlines"])
        let tool = RecordingTool(name: ToolName.webSearch, terminal: false, summary: "Found 5 web results.",
                                 requiresModelAnswer: true)
        let agent = AgentService(llm: llm, registry: ToolRegistry(tools: [tool]), router: noApps, confirm: { _ in true })
        let result = await collect(agent.run("Can you search the internet for public APIs for my AI app?"))
        #expect(tool.calls.count == 1)
        #expect(result.outcome?.text == "- OpenWeather: free weather data\n- NewsAPI: headlines")
        #expect(result.outcome?.cards.count == 1)
        let messages = try #require(llm.received.first)
        #expect(messages.last?.role == .tool)
        #expect(messages.dropLast().last?.toolCalls.first?.name == ToolName.webSearch)
    }

    @Test("Chained requests keep going until every part has a tool, then report all results")
    func chainedCommands() async {
        let llm = FakeLLM(responses: [
            #"<tool_call>{"name": "reminders_create", "arguments": {"title": "Call Alex", "due": "tomorrow at 9"}}</tool_call>"#,
            #"<tool_call>{"name": "calendar_create", "arguments": {"title": "Call Alex", "start": "tomorrow at 9"}}</tool_call>"#,
        ])
        let reminder = RecordingTool(name: ToolName.remindersCreate, summary: "Reminder set: Call Alex for tomorrow at 9:00.")
        let event = RecordingTool(name: ToolName.calendarCreate, summary: "Added “Call Alex” to your calendar tomorrow at 9:00.")
        let agent = AgentService(llm: llm, registry: ToolRegistry(tools: [reminder, event]), router: noApps, confirm: { _ in true })
        let result = await collect(agent.run("Remind me tomorrow at 9 to call Alex, and set it up in Calendar too"))
        #expect(reminder.calls.count == 1)
        #expect(event.calls.count == 1)
        #expect(llm.received.count == 2)
        #expect(result.outcome?.text == "Reminder set: Call Alex for tomorrow at 9:00. Added “Call Alex” to your calendar tomorrow at 9:00.")
        #expect(result.outcome?.cards.count == 2)
    }

    @Test("The situation (Focus) is added to the model's context line")
    func focusContext() async throws {
        let llm = FakeLLM(responses: ["Sure."])
        let agent = AgentService(llm: llm, registry: ToolRegistry(), router: noApps, fastRoutingEnabled: { false },
                                 situation: { "Focus: Work. Be brief and professional." }, confirm: { _ in true })
        _ = await collect(agent.run("how should I phrase this?"))
        let user = try #require(llm.received.first?.last)
        #expect(user.content.contains("[Focus: Work. Be brief and professional.]"))
    }

    @Test("Huge tool errors are clipped and never bloat the next prompt")
    func hugeErrorsAreClipped() async throws {
        struct FailingTool: IVYTool {
            let name = ToolName.mailSearch
            let description = "fails"
            let parameters: [ToolParameter] = []
            let displayName = "Mail"
            let baseRisk = RiskLevel.low
            func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
                throw ToolError.failed(String(repeating: "message id 1051 of mailbox \"INBOX\" of account id X, ", count: 2000))
            }
        }
        let llm = FakeLLM(responses: [#"<tool_call>{"name": "mail_search", "arguments": {}}</tool_call>"#, "OK."])
        let agent = AgentService(llm: llm, registry: ToolRegistry(tools: [FailingTool()]), router: noApps,
                                 fastRoutingEnabled: { false }, confirm: { _ in true })
        let first = await collect(agent.run("any mail?"))
        #expect((first.outcome?.text.count ?? 0) <= 300)
        _ = await collect(agent.run("run my lights shortcut"))
        let prompt = try #require(llm.received.last)
        #expect(prompt.reduce(0) { $0 + $1.content.count } < 8_000)
    }

    @Test("Old turns are dropped when the prompt would overflow the context")
    func contextBudgetDropsHistory() {
        var messages: [ChatMessage] = [.system("system")]
        for index in 0..<20 {
            messages.append(.user("question \(index) " + String(repeating: "x", count: 2_000)))
            messages.append(.assistant("answer"))
        }
        messages.append(.user("current request"))
        var historyEnd = messages.count - 1
        ContextBudget.fit(&messages, historyEnd: &historyEnd, toolSchemas: [],
                          options: GenerationOptions(maxTokens: 320, contextLength: 4096))
        #expect(messages.first?.role == .system)
        #expect(messages.last?.content == "current request")
        #expect(messages.count < 42)
        #expect(messages.reduce(0) { $0 + $1.content.count } / 3 < 4096)
    }

    @Test("Model tool call is parsed, executed, and terminal tools skip the second pass")
    func modelToolCallTerminal() async {
        let llm = FakeLLM(responses: [#"<tool_call>{"name": "music_play", "arguments": {"query": "Thriller"}}</tool_call>"#])
        let tool = RecordingTool(name: ToolName.musicPlay, summary: "Playing Thriller by Michael Jackson.")
        let agent = AgentService(llm: llm, registry: ToolRegistry(tools: [tool]), router: noApps,
                                 fastRoutingEnabled: { false }, confirm: { _ in true })
        let result = await collect(agent.run("put on something from thriller"))
        #expect(tool.calls == [["query": "Thriller"]])
        #expect(result.outcome?.text == "Playing Thriller by Michael Jackson.")
        #expect(result.outcome?.cards.count == 1)
        #expect(llm.received.count == 1)
    }

    @Test("Non-terminal tools feed the result back to the model for a short answer")
    func nonTerminalSecondPass() async throws {
        let llm = FakeLLM(responses: [
            #"<tool_call>{"name": "reminders_list", "arguments": {"scope": "today"}}</tool_call>"#,
            "You have 3 reminders today: homework, meeting at 7 PM, and VoiceOS deals.",
        ])
        let tool = RecordingTool(name: ToolName.remindersList, terminal: false, summary: "You have three reminders due today.")
        let agent = AgentService(llm: llm, registry: ToolRegistry(tools: [tool]), router: noApps,
                                 fastRoutingEnabled: { false }, confirm: { _ in true })
        let result = await collect(agent.run("what's on my plate?"))
        #expect(result.outcome?.text == "You have 3 reminders today: homework, meeting at 7 PM, and VoiceOS deals.")
        #expect(llm.received.count == 2)
        let second = try #require(llm.received.last)
        #expect(second.last?.role == .tool)
        #expect(second.last?.content.contains("three reminders") == true)
    }

    @Test("Plain answers need no tools")
    func plainAnswer() async {
        let llm = FakeLLM(responses: ["Canberra."])
        let agent = AgentService(llm: llm, registry: ToolRegistry(), router: noApps, confirm: { _ in true })
        let result = await collect(agent.run("Capital of Australia?"))
        #expect(result.outcome?.text == "Canberra.")
        #expect(result.outcome?.usedModel == true)
        #expect(llm.loadCount == 1)
    }

    @Test("High-risk tools ask for confirmation and respect a denial")
    func highRiskDenied() async {
        let llm = FakeLLM(responses: [#"<tool_call>{"name": "move_to_trash", "arguments": {"value": "x"}}</tool_call>"#])
        let tool = RecordingTool(name: ToolName.moveToTrash, risk: .high)
        let asked = Counter()
        let agent = AgentService(llm: llm, registry: ToolRegistry(tools: [tool]), router: noApps,
                                 fastRoutingEnabled: { false }, confirm: { _ in asked.increment(); return false })
        let result = await collect(agent.run("delete that file"))
        #expect(asked.value == 1)
        #expect(tool.calls.isEmpty)
        #expect(result.outcome?.status == .cancelled)
    }

    @Test("High-risk tools run after approval; low-risk tools never ask")
    func highRiskApproved() async {
        let llm = FakeLLM(responses: [#"<tool_call>{"name": "move_to_trash", "arguments": {}}</tool_call>"#,
                                      #"<tool_call>{"name": "open_app", "arguments": {"name": "Notes"}}</tool_call>"#])
        let trash = RecordingTool(name: ToolName.moveToTrash, risk: .high)
        let open = RecordingTool(name: ToolName.openApp, risk: .low)
        let asked = Counter()
        let agent = AgentService(llm: llm, registry: ToolRegistry(tools: [trash, open]), router: noApps,
                                 fastRoutingEnabled: { false }, confirm: { _ in asked.increment(); return true })
        _ = await collect(agent.run("trash it"))
        _ = await collect(agent.run("open notes"))
        #expect(trash.calls.count == 1)
        #expect(open.calls.count == 1)
        #expect(asked.value == 1)
    }

    @Test("Unknown tools produce a failure instead of crashing")
    func unknownTool() async {
        let llm = FakeLLM(responses: [#"<tool_call>{"name": "format_disk", "arguments": {}}</tool_call>"#,
                                      "I can't do that."])
        let agent = AgentService(llm: llm, registry: ToolRegistry(), router: noApps,
                                 fastRoutingEnabled: { false }, confirm: { _ in true })
        let result = await collect(agent.run("format my disk"))
        #expect(result.outcome?.text == "I can't do that.")
    }

    @Test("Registry normalizes tool names emitted by the model")
    func registryNormalizes() {
        let registry = ToolRegistry(tools: [RecordingTool(name: "music_play")])
        #expect(registry.tool(named: "Music-Play")?.name == "music_play")
        #expect(registry.schemas.count == 1)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite("ToolCallParser")
struct ToolCallParserTests {
    @Test func parsesQwenFormat() {
        let raw = "<tool_call>\n{\"name\": \"reminders_create\", \"arguments\": {\"title\": \"buy milk\", \"due\": \"Friday at 6pm\"}}\n</tool_call>"
        let parsed = ToolCallParser.parse(raw)
        #expect(parsed.toolCalls == [ToolCall(name: "reminders_create", arguments: ["title": "buy milk", "due": "Friday at 6pm"])])
        #expect(parsed.text.isEmpty)
    }

    @Test func toleratesMissingCloseTagThinkingAndFences() {
        let raw = "<think>\nhmm\n</think>\n<tool_call>```json\n{\"name\": \"open_app\", \"arguments\": \"{\\\"name\\\": \\\"Notes\\\"}\"}```"
        let parsed = ToolCallParser.parse(raw)
        #expect(parsed.toolCalls == [ToolCall(name: "open_app", arguments: ["name": "Notes"])])
    }

    @Test func bareJSONObject() {
        let parsed = ToolCallParser.parse(#"{"name": "music_now_playing", "arguments": {}}"#)
        #expect(parsed.toolCalls.first?.name == "music_now_playing")
    }

    @Test func plainTextIsNotAToolCall() {
        let parsed = ToolCallParser.parse("<think></think>\n\nThe capital of Australia is Canberra.")
        #expect(parsed.toolCalls.isEmpty)
        #expect(parsed.text == "The capital of Australia is Canberra.")
    }

    @Test func streamingPrefixDetection() {
        #expect(ToolCallParser.looksLikeToolCallPrefix("<tool"))
        #expect(ToolCallParser.looksLikeToolCallPrefix("\n<tool_call>{\"na"))
        #expect(ToolCallParser.looksLikeToolCallPrefix(""))
        #expect(!ToolCallParser.looksLikeToolCallPrefix("The capital"))
    }

    @Test func messageEncodingMatchesChatTemplate() {
        let message = ChatMessage.assistant("", toolCalls: [ToolCall(name: "open_app", arguments: ["name": "Notes"])])
        let json = message.jsonValue
        #expect(json["role"] == "assistant")
        #expect(json["tool_calls"]?.arrayValue?.first?["function"]?["name"] == "open_app")
    }
}
