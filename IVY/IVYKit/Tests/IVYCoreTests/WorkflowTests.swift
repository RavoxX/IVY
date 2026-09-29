import Foundation
import Testing
@testable import IVYCore

private let noApps = CommandRouter(resolveApp: { _ in nil })

private func outcome(of stream: AsyncStream<AgentEvent>) async -> (AgentOutcome?, [AgentEvent]) {
    var events: [AgentEvent] = []
    var result: AgentOutcome?
    for await event in stream {
        events.append(event)
        if case .finished(let value) = event { result = value }
    }
    return (result, events)
}

@Suite("Workflow improvements")
struct WorkflowTests {
    @Test func toolHints() {
        #expect(ToolHints.relevant(for: "Any new mail from Alex?") == [ToolName.mailSearch])
        #expect(ToolHints.relevant(for: "Turn on low power mode").contains(ToolName.lowPowerMode))
        #expect(!ToolHints.relevant(for: "Turn on low power mode").contains(ToolName.focus))
        #expect(ToolHints.relevant(for: "Stell den Fokus auf nicht stören") == [ToolName.focus])
        #expect(ToolHints.relevant(for: "What's the capital of Australia?").isEmpty)
    }

    @Test func hintsReachTheModel() async throws {
        let llm = FakeLLM(responses: ["Canberra."])
        let agent = AgentService(llm: llm, registry: ToolRegistry(), router: noApps, fastRoutingEnabled: { false },
                                 confirm: { _ in true })
        _ = await outcome(of: agent.run("any new mail from alex?"))
        let request = try #require(llm.received.first?.last)
        #expect(request.content.contains("[Likely tools: mail_search]"))
    }

    @Test func learnsFromCorrections() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("phrases-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let memory = PhraseMemory(fileURL: file)
        let start = Date()
        memory.record(query: "nicht stören an", outcome: .failed, now: start)
        let call = ToolCall(name: ToolName.focus, arguments: ["action": "on", "name": "Do Not Disturb"])
        memory.record(query: "turn on do not disturb", outcome: .tool(call), now: start.addingTimeInterval(20))
        #expect(memory.lookup("Nicht stören an!") == call)
        // Persisted.
        #expect(PhraseMemory(fileURL: file).lookup("nicht stören an") == call)
        memory.forget("nicht stören an")
        #expect(memory.lookup("nicht stören an") == nil)
    }

    @Test func doesNotLearnUnrelatedOrRiskyThings() {
        let memory = PhraseMemory(fileURL: nil)
        let start = Date()
        // A plain answer followed by an unrelated command isn't a correction.
        memory.record(query: "what's the capital of france", outcome: .plainAnswer, now: start)
        memory.record(query: "pause the music", outcome: .tool(ToolCall(name: ToolName.musicControl)), now: start.addingTimeInterval(5))
        #expect(memory.lookup("what's the capital of france") == nil)
        // Time-dependent tools aren't learned.
        memory.record(query: "remind me later about it", outcome: .failed, now: start)
        memory.record(query: "remind me at 5 to call alex", outcome: .tool(ToolCall(name: ToolName.remindersCreate)), now: start.addingTimeInterval(5))
        #expect(memory.lookup("remind me later about it") == nil)
        // Too late to count as a correction.
        memory.record(query: "lights please", outcome: .failed, now: start)
        memory.record(query: "run the shortcut lights", outcome: .tool(ToolCall(name: ToolName.shortcutRun)), now: start.addingTimeInterval(300))
        #expect(memory.lookup("lights please") == nil)
        // A plain answer that missed, then a rephrase about the same thing, is learned.
        memory.record(query: "is my battery okay", outcome: .plainAnswer, now: start)
        memory.record(query: "how's my battery health", outcome: .tool(ToolCall(name: ToolName.energyStatus)), now: start.addingTimeInterval(10))
        #expect(memory.lookup("is my battery okay")?.name == ToolName.energyStatus)
    }

    @Test func agentUsesLearnedPhrasesAndLearns() async {
        let memory = PhraseMemory(fileURL: nil)
        let llm = FakeLLM(responses: ["I can't do that yet."])
        let tool = RecordingTool(name: ToolName.focus, summary: "Nicht stören Focus is on.")
        let agent = AgentService(llm: llm, registry: ToolRegistry(tools: [tool]), router: noApps,
                                 fastRoutingEnabled: { false }, phrases: memory, confirm: { _ in true })
        // The model answers without a tool; the user rephrases and the model calls the tool.
        _ = await outcome(of: agent.run("mach nicht stören an"))
        llm.responses = [#"<tool_call>{"name": "focus", "arguments": {"action": "on", "name": "Do Not Disturb"}}</tool_call>"#]
        _ = await outcome(of: agent.run("turn on nicht stören focus"))
        #expect(memory.lookup("mach nicht stören an")?.name == ToolName.focus)
        // Next time the original words run the tool directly, without the model.
        let before = llm.received.count
        let (result, _) = await outcome(of: agent.run("Mach nicht stören an"))
        #expect(result?.text == "Nicht stören Focus is on.")
        #expect(llm.received.count == before)
    }

    @Test func ambiguityHelpers() {
        let mail = [
            MailMessageItem(id: "1", sender: "Alex Kim <a@x.com>", subject: "Hi", date: Date(), isRead: false),
            MailMessageItem(id: "2", sender: "Alex Meyer <m@y.com>", subject: "Yo", date: Date(), isRead: false),
        ]
        #expect(MailFilter.ambiguousSenders(in: mail, for: "alex") == ["Alex Kim", "Alex Meyer"])
        #expect(MailFilter.ambiguousSenders(in: mail, for: "alex kim") == nil)
        #expect(MailFilter.ambiguousSenders(in: Array(mail.prefix(1)), for: "alex") == nil)

        let reminders = [ReminderItem(id: "1", title: "Call Alex", dueDate: nil, hasDueTime: false),
                         ReminderItem(id: "2", title: "Call the bank", dueDate: nil, hasDueTime: false)]
        #expect(ReminderTransforms.ambiguousMatches(for: "call", in: reminders)?.count == 2)
        #expect(ReminderTransforms.ambiguousMatches(for: "call alex", in: reminders) == nil)

        let shortcuts = [ShortcutInfo(name: "Lights Kitchen", id: "1"), ShortcutInfo(name: "Lights Bedroom", id: "2"),
                         ShortcutInfo(name: "Thermostat", id: "3")]
        #expect(ShortcutMatcher.ambiguous(for: "lights", in: shortcuts)?.count == 2)
        #expect(ShortcutMatcher.ambiguous(for: "kitchen lights", in: shortcuts) == nil)
    }

    @Test func toolQuestionsStopAndWaitForAReply() async {
        struct AskingTool: IVYTool {
            let name = ToolName.mailSearch
            let description = "asks"
            let parameters: [ToolParameter] = []
            let displayName = "Mail"
            let baseRisk = RiskLevel.low
            func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
                .question("Which Alex do you mean: Alex Kim or Alex Meyer?")
            }
        }
        let llm = FakeLLM(responses: [#"<tool_call>{"name": "mail_search", "arguments": {"from": "alex"}}</tool_call>"#])
        let agent = AgentService(llm: llm, registry: ToolRegistry(tools: [AskingTool()]), router: noApps,
                                 fastRoutingEnabled: { false }, confirm: { _ in true })
        let (result, _) = await outcome(of: agent.run("mail from alex?"))
        #expect(result?.needsReply == true)
        #expect(result?.text == "Which Alex do you mean: Alex Kim or Alex Meyer?")
        #expect(llm.received.count == 1)
    }

    @Test func writingModelAnswersFromToolResults() async throws {
        let main = FakeLLM(responses: [])
        let writer = FakeLLM(responses: ["Try OpenWeather and NewsAPI."])
        let tool = RecordingTool(name: ToolName.webSearch, terminal: false, summary: "Found 5 web results.",
                                 requiresModelAnswer: true)
        let agent = AgentService(llm: main, registry: ToolRegistry(tools: [tool]), router: noApps,
                                 writer: { writer }, confirm: { _ in true })
        let (result, _) = await outcome(of: agent.run("search the web for public apis"))
        #expect(result?.text == "Try OpenWeather and NewsAPI.")
        #expect(main.received.isEmpty)
        #expect(writer.received.count == 1)
    }

    @Test func warmUpPrefillsOnceWhileLoaded() async throws {
        let llm = FakeLLM(responses: [])
        let tool = RecordingTool(name: ToolName.musicControl)
        let agent = AgentService(llm: llm, registry: ToolRegistry(tools: [tool]), router: noApps, confirm: { _ in true })
        await agent.warmUp()
        await agent.warmUp()
        #expect(llm.received.count == 1)
        let messages = try #require(llm.received.first)
        #expect(messages.first?.content == SystemPrompt.text)
        await llm.unloadModel()
        await agent.warmUp()
        #expect(llm.received.count == 2)
    }

    @Test func toolsCanStreamPreviews() async {
        struct StreamingTool: IVYTool {
            let name = ToolName.clipboard
            let description = "streams"
            let parameters: [ToolParameter] = []
            let displayName = "Clipboard"
            let baseRisk = RiskLevel.low
            func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
                context.preview(.text(title: "Summary", body: "Part"))
                return ToolResult(summary: "Done.", card: .text(title: "Summary", body: "Part one."))
            }
        }
        let agent = AgentService(llm: FakeLLM(responses: []), registry: ToolRegistry(tools: [StreamingTool()]),
                                 router: noApps, confirm: { _ in true })
        let (_, events) = await outcome(of: agent.run("summarize my clipboard"))
        #expect(events.contains { if case .cardPreview(.text("Summary", "Part")) = $0 { return true } else { return false } })
    }
}
