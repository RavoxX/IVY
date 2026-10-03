import Foundation

public struct BenchmarkCase: Sendable, Identifiable {
    public let id: String
    public let requests: [String]
    public let expectedTools: [String]
    public let mustAsk: Bool
    public let initialFailure: String?
    public init(_ id: String, _ requests: [String], expectedTools: [String], mustAsk: Bool = false, initialFailure: String? = nil) {
        self.id = id; self.requests = requests; self.expectedTools = expectedTools; self.mustAsk = mustAsk; self.initialFailure = initialFailure
    }
    public static let daily: [BenchmarkCase] = [
        .init("en-reminder", ["Remind me tomorrow at 9 to call Alex"], expectedTools: [ToolName.remindersCreate]),
        .init("de-reminder", ["Erinnere mich morgen um 9 Uhr daran, Alex anzurufen"], expectedTools: [ToolName.remindersCreate]),
        .init("en-calendar", ["What's on my calendar tomorrow?"], expectedTools: [ToolName.calendarEvents]),
        .init("de-calendar", ["Welche Termine habe ich morgen?"], expectedTools: [ToolName.calendarEvents]),
        .init("en-timer", ["Set a timer for 10 minutes"], expectedTools: [ToolName.timerSet]),
        .init("de-timer", ["Stelle einen Timer auf zehn Minuten"], expectedTools: [ToolName.timerSet]),
        .init("chained", ["Remind me tomorrow at 9 to call Alex and add it to my calendar too"], expectedTools: [ToolName.remindersCreate, ToolName.calendarCreate]),
        .init("event-follow-up", ["Find tomorrow's meeting", "Move it to Friday", "Make it an hour later"], expectedTools: [ToolName.calendarEvents, ToolName.calendarUpdate, ToolName.calendarUpdate]),
        .init("ambiguous-event", ["Move my meeting to Friday"], expectedTools: [ToolName.calendarEvents], mustAsk: true),
        .init("failed-tool", ["Remind me tomorrow to call Alex"], expectedTools: [ToolName.remindersCreate], initialFailure: ToolName.remindersCreate),
        .init("correction", ["Set a timer for 10 minutes", "No, cancel that timer"], expectedTools: [ToolName.timerSet, ToolName.timerCancel]),
        .init("web-answer", ["Search the internet for how tall the Eiffel Tower is"], expectedTools: [ToolName.webSearch])
    ]
}

public struct BenchmarkResult: Codable, Sendable, Identifiable {
    public var id: String
    public var passed: Bool
    public var wrongActions: Int
    public var calls: [ToolCall]
    public var seconds: Double
    public var detail: String
}

public actor AssistantBenchmark {
    private let llm: any LocalLLMService
    private let options: GenerationOptions
    private var cancelled = false
    public init(llm: any LocalLLMService, options: GenerationOptions) { self.llm = llm; self.options = options }
    public func cancel() async { cancelled = true; await llm.cancelGeneration() }

    /// Uses synthetic tools only. No real reminders, events, files, messages or settings change.
    /// The configured API model is billed for its actual requests.
    public func run(onResult: @escaping @Sendable (BenchmarkResult) async -> Void) async {
        cancelled = false
        for test in BenchmarkCase.daily {
            guard !cancelled, !Task.isCancelled else { break }
            let recorder = BenchmarkRecorder(failure: test.initialFailure, ambiguous: test.mustAsk)
            let registry = ToolRegistry(tools: [
                BenchmarkTool(name: ToolName.remindersCreate, recorder: recorder, parameters: [ToolParameter("title", .string, "Reminder title", required: true), ToolParameter("due", .string, "Date in the user's words")]),
                BenchmarkTool(name: ToolName.calendarCreate, recorder: recorder, parameters: [ToolParameter("title", .string, "Event title", required: true), ToolParameter("start", .string, "Event start in the user's words", required: true)]),
                BenchmarkTool(name: ToolName.calendarEvents, recorder: recorder, parameters: [ToolParameter("scope", .string, "today, tomorrow or week")]),
                BenchmarkTool(name: ToolName.calendarUpdate, recorder: recorder, parameters: [ToolParameter("id", .string, "Exact event ID from calendar_events", required: true), ToolParameter("start", .string, "New start date"), ToolParameter("offset_minutes", .integer, "Shift by minutes")]),
                BenchmarkTool(name: ToolName.timerSet, recorder: recorder, parameters: [ToolParameter("duration", .string, "Length in user's words", required: true)]),
                BenchmarkTool(name: ToolName.timerCancel, recorder: recorder, parameters: []),
                BenchmarkTool(name: ToolName.webSearch, recorder: recorder, parameters: [ToolParameter("query", .string, "Search question", required: true)])
            ])
            let agent = AgentService(llm: llm, registry: registry, router: CommandRouter(resolveApp: { _ in nil }),
                options: { [options] in options }, fastRoutingEnabled: { false }, confirm: { _ in true })
            var final: AgentOutcome?; var error: String?
            let started = Date()
            for request in test.requests {
                guard !cancelled, !Task.isCancelled else { break }
                for await event in agent.run(request) {
                    if case .finished(let result) = event { final = result }
                    if case .failed(let failure) = event { error = failure }
                }
            }
            guard !cancelled, !Task.isCancelled else { break }
            let calls = await recorder.calls
            let actual = calls.map(\.name)
            var wrong = 0
            for (index, call) in calls.enumerated() {
                if index >= test.expectedTools.count || call.name != test.expectedTools[index] { wrong += 1 }
                if call.name == ToolName.calendarUpdate && call.arguments.string("id") != "event-standup" { wrong += 1 }
                if call.name == ToolName.timerSet, DurationParser.seconds(in: call.arguments.string("duration") ?? "") != 600 { wrong += 1 }
            }
            let asked = final?.needsReply == true || final?.text.contains("?") == true
            let pass = actual == test.expectedTools && wrong == 0 && error == nil &&
                (!test.mustAsk || asked) && (test.initialFailure == nil || final?.status == .failure)
            await onResult(BenchmarkResult(id: test.id, passed: pass, wrongActions: wrong, calls: calls,
                seconds: Date().timeIntervalSince(started), detail: error ?? (pass ? "Expected task behavior observed." : "Unexpected calls, missing clarification, or failure handling.")))
        }
    }
}

private actor BenchmarkRecorder {
    private(set) var calls: [ToolCall] = []
    let failure: String?
    let ambiguous: Bool
    init(failure: String?, ambiguous: Bool) { self.failure = failure; self.ambiguous = ambiguous }
    func execute(_ call: ToolCall) -> ToolResult {
        calls.append(call)
        if call.name == failure { return .failure("Synthetic service unavailable. Don't claim success or retry this write automatically.") }
        switch call.name {
        case ToolName.calendarEvents:
            if ambiguous {
                return ToolResult(summary: "Found two meetings.",
                    data: ["events": [["id": "event-a", "title": "Standup"], ["id": "event-b", "title": "Planning"]]])
            }
            return ToolResult(summary: "Found tomorrow's standup.", data: ["events": [["id": "event-standup", "title": "Standup", "start": "tomorrow at 09:00"]]])
        case ToolName.calendarUpdate:
            guard call.arguments.string("id") == "event-standup" else { return .failure("Unknown event ID") }
            return ToolResult(summary: "Moved Standup.", data: ["event": ["id": "event-standup", "title": "Standup", "start": call.arguments["start"] ?? "Friday at 10:00"]])
        case ToolName.webSearch:
            return ToolResult(summary: "Found sources.", data: ["sources": [["title": "Official Eiffel Tower", "url": "https://www.toureiffel.paris", "excerpt": "The Eiffel Tower is 330 meters tall."]]])
        default: return ToolResult(summary: "Synthetic \(call.name) succeeded.")
        }
    }
}
private struct BenchmarkTool: IVYTool {
    let name: String
    let recorder: BenchmarkRecorder
    let parameters: [ToolParameter]
    var description: String { "Synthetic benchmark tool: " + name }
    var displayName: String { name }
    let baseRisk = RiskLevel.low
    var isTerminal: Bool { name != ToolName.webSearch && name != ToolName.calendarEvents }
    var requiresModelAnswer: Bool { name == ToolName.webSearch }
    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        for parameter in parameters where parameter.required { guard arguments[parameter.name] != nil else { throw ToolError.missingArgument(parameter.name) } }
        return await recorder.execute(ToolCall(name: name, arguments: arguments))
    }
}
