import Foundation
import Testing
@testable import IVYCore

@Suite("DurationParser")
struct DurationParserTests {
    @Test func parsesCommonPhrases() {
        #expect(DurationParser.seconds(in: "5 minutes") == 300)
        #expect(DurationParser.seconds(in: "set a timer for ten minutes") == 600)
        #expect(DurationParser.seconds(in: "an hour and a half") == 5400)
        #expect(DurationParser.seconds(in: "1h 30m") == 5400)
        #expect(DurationParser.seconds(in: "half an hour") == 1800)
        #expect(DurationParser.seconds(in: "90 seconds") == 90)
        #expect(DurationParser.seconds(in: "twenty five minutes") == 1500)
        #expect(DurationParser.seconds(in: "a minute") == 60)
        #expect(DurationParser.seconds(in: "at 12 a.m.") == nil)
        #expect(DurationParser.seconds(in: "call alex") == nil)
    }

    @Test func formats() {
        #expect(DurationParser.describe(5400) == "1 hour 30 minutes")
        #expect(DurationParser.describe(90) == "1 minute 30 seconds")
        #expect(DurationParser.countdown(299.2) == "5:00")
        #expect(DurationParser.countdown(3723) == "1:02:03")
    }
}

@Suite("Calculator")
struct CalculatorTests {
    @Test func evaluates() throws {
        #expect(try Calculator.evaluate("2 + 3 * 4") == 14)
        #expect(try Calculator.evaluate("(2 + 3) * 4") == 20)
        #expect(try Calculator.evaluate("2 ^ 10") == 1024)
        #expect(try Calculator.evaluate("-3 + 5") == 2)
        #expect(try Calculator.evaluate("15% of 80") == 12)
        #expect(try Calculator.evaluate("12 times 3 plus 1") == 37)
        #expect(try Calculator.evaluate("square root of 144") == 12)
        #expect(try Calculator.evaluate("1,250 / 5") == 250)
        #expect(Calculator.format(2.5) == "2.5")
        #expect(Calculator.format(12) == "12")
    }

    @Test func rejectsUnsafeOrInvalidInput() {
        #expect(throws: Calculator.CalcError.divisionByZero) { try Calculator.evaluate("1 / 0") }
        #expect(throws: (any Error).self) { try Calculator.evaluate("FUNCTION('a', 'b')") }
        #expect(throws: (any Error).self) { try Calculator.evaluate("2 +") }
        #expect(!Calculator.looksLikeMath("what's the capital of france"))
        #expect(Calculator.looksLikeMath("12 * 7"))
    }
}

@Suite("Router: new commands")
struct RouterExtraTests {
    let router = CommandRouter(resolveApp: { name in
        ["safari": "Safari", "google chrome": "Google Chrome", "chrome": "Google Chrome", "claude": "Claude"][name.lowercased()]
    })

    @Test func songQueriesAreCleaned() {
        #expect(router.route("Play Timber from Spotify.") == ToolCall(name: ToolName.musicPlay, arguments: ["query": "timber"]))
        #expect(router.route("play the song blinding lights on spotify")
            == ToolCall(name: ToolName.musicPlay, arguments: ["query": "blinding lights"]))
        #expect(router.route("Play Billie Jean") == ToolCall(name: ToolName.musicPlay, arguments: ["query": "billie jean"]))
    }

    @Test func openClaudeCodeWithoutTask() {
        #expect(router.route("Open Claude Code") == ToolCall(name: ToolName.startCodingSession, arguments: ["agent": "claude"]))
        #expect(router.route("start a claude code session")
            == ToolCall(name: ToolName.startCodingSession, arguments: ["agent": "claude"]))
        // The Claude desktop app itself is just an app.
        #expect(router.route("open claude") == ToolCall(name: ToolName.openApp, arguments: ["name": "Claude"]))
        let build = router.route("Open Claude Code and start building a personal website")
        #expect(build?.arguments["task"] == "Build a personal website")
    }

    @Test func browserSearch() {
        #expect(router.route("Open Google Chrome and get an article about the Eiffel Tower.")
            == ToolCall(name: ToolName.browserSearch, arguments: ["query": "article about the eiffel tower", "browser": "Google Chrome"]))
        #expect(router.route("open chrome and search for eiffel tower")
            == ToolCall(name: ToolName.browserSearch, arguments: ["query": "eiffel tower", "browser": "Google Chrome"]))
        #expect(router.route("google best pizza in berlin")
            == ToolCall(name: ToolName.browserSearch, arguments: ["query": "best pizza in berlin"]))
        #expect(router.route("search for cats in safari")
            == ToolCall(name: ToolName.browserSearch, arguments: ["query": "cats", "browser": "Safari"]))
        #expect(router.route("look up the population of japan")
            == ToolCall(name: ToolName.webSearch, arguments: ["query": "the population of japan"]))
    }

    @Test func timers() throws {
        #expect(router.route("Set a timer for 5 minutes") == ToolCall(name: ToolName.timerSet, arguments: ["duration": "5 minutes"]))
        #expect(router.route("10 minute timer") == ToolCall(name: ToolName.timerSet, arguments: ["duration": "10 minutes"]))
        #expect(router.route("set a timer for 20 minutes for the pasta")
            == ToolCall(name: ToolName.timerSet, arguments: ["duration": "20 minutes", "label": "pasta"]))
        let alarm = try #require(router.route("Set up a timer for 12 a.m."))
        #expect(alarm.name == ToolName.timerSet)
        let at = try #require(alarm.arguments.string("at").flatMap { NaturalDateParser.parseISO($0) })
        #expect(Calendar.current.component(.hour, from: at.date) == 0)
        #expect(router.route("wake me up at 7am")?.name == ToolName.timerSet)
        #expect(router.route("cancel the timer") == ToolCall(name: ToolName.timerCancel))
        #expect(router.route("how much time is left") == ToolCall(name: ToolName.timerList))
    }

    @Test func mathSystemWeatherCalendar() {
        #expect(router.route("what's 12 times 7") == ToolCall(name: ToolName.calculate, arguments: ["expression": "12 times 7"]))
        #expect(router.route("turn on dark mode") == ToolCall(name: ToolName.darkMode, arguments: ["mode": "dark"]))
        #expect(router.route("mute") == ToolCall(name: ToolName.systemVolume, arguments: ["action": "mute"]))
        #expect(router.route("how much battery do I have") == ToolCall(name: ToolName.systemInfo, arguments: ["kind": "battery"]))
        #expect(router.route("what time is it") == ToolCall(name: ToolName.systemInfo, arguments: ["kind": "time"]))
        #expect(router.route("what's the weather in paris tomorrow")
            == ToolCall(name: ToolName.weather, arguments: ["location": "Paris", "day": "tomorrow"]))
        #expect(router.route("what's the weather") == ToolCall(name: ToolName.weather))
        #expect(router.route("what's on my calendar today") == ToolCall(name: ToolName.calendarEvents, arguments: ["scope": "today"]))
        // Regular questions still go to the model.
        #expect(router.route("who wrote the odyssey") == nil)
    }
}

@Suite("Action claim guard")
struct ActionClaimGuardTests {
    @Test func flagsUnbackedClaims() {
        #expect(ActionClaimGuard.isUnbacked(answer: "I opened Chrome and searched for \"Eiffel Tower article\".",
                                            query: "Open Google Chrome and get an article about the Eiffel Tower."))
        #expect(ActionClaimGuard.isUnbacked(answer: "Timer set for 5 minutes.", query: "set a timer for 5 minutes"))
        #expect(ActionClaimGuard.isUnbacked(answer: "To open Chrome, click its icon in the Dock.", query: "open chrome"))
        #expect(!ActionClaimGuard.isUnbacked(answer: "The capital of France is Paris.", query: "what's the capital of france"))
        #expect(!ActionClaimGuard.isUnbacked(answer: "I can't do that yet.", query: "book a flight"))
    }

    @Test func agentRetriesThenAdmitsFailure() async {
        let llm = FakeLLM(responses: ["I opened Chrome for you.", "I opened Chrome for you."])
        let agent = AgentService(llm: llm, registry: ToolRegistry(), router: CommandRouter(resolveApp: { _ in nil }),
                                 fastRoutingEnabled: { false }, confirm: { _ in true })
        var outcome: AgentOutcome?
        for await event in agent.run("open chrome") {
            if case .finished(let result) = event { outcome = result }
        }
        #expect(llm.received.count == 2)
        #expect(outcome?.text == ActionClaimGuard.fallback)
        #expect(outcome?.status == .failure)
    }

    @Test func agentRetrySucceedsWithTool() async {
        let llm = FakeLLM(responses: ["Done, Chrome is open.",
                                      #"<tool_call>{"name": "open_app", "arguments": {"name": "Google Chrome"}}</tool_call>"#])
        let tool = RecordingTool(name: ToolName.openApp, summary: "Opened Google Chrome.")
        let agent = AgentService(llm: llm, registry: ToolRegistry(tools: [tool]), router: CommandRouter(resolveApp: { _ in nil }),
                                 fastRoutingEnabled: { false }, confirm: { _ in true })
        var outcome: AgentOutcome?
        for await event in agent.run("open chrome") {
            if case .finished(let result) = event { outcome = result }
        }
        #expect(tool.calls.count == 1)
        #expect(outcome?.text == "Opened Google Chrome.")
    }
}
