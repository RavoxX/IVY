import Foundation

public struct ConfirmationRequest: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var toolName: String
    public var displayName: String
    public var prompt: String
    public var risk: RiskLevel

    public init(id: UUID = UUID(), toolName: String, displayName: String, prompt: String, risk: RiskLevel) {
        self.id = id
        self.toolName = toolName
        self.displayName = displayName
        self.prompt = prompt
        self.risk = risk
    }
}

public struct AgentOutcome: Sendable, Equatable {
    public var text: String
    public var cards: [ResultCard]
    public var toolNames: [String]
    public var status: HistoryEntry.Status
    public var usedModel: Bool

    public init(text: String, cards: [ResultCard] = [], toolNames: [String] = [], status: HistoryEntry.Status = .success,
                usedModel: Bool = false) {
        self.text = text
        self.cards = cards
        self.toolNames = toolNames
        self.status = status
        self.usedModel = usedModel
    }
}

public enum AgentEvent: Sendable {
    case modelLoading
    case thinking
    /// Cumulative visible answer text while the model streams.
    case partialText(String)
    case toolStarted(ToolCall, displayName: String)
    case awaitingConfirmation(ConfirmationRequest)
    case toolFinished(ToolCall, ToolResult)
    case finished(AgentOutcome)
    case failed(String)
}

/// Orchestrates one request: fast routing → local LLM → validated tool calls → short answer.
///
/// ```
/// user input ─▶ CommandRouter ──(match)──────────────▶ tool ─▶ summary
///            └─▶ LLM ─▶ <tool_call>? ─▶ confirm? ─▶ tool ─▶ LLM (short answer)
/// ```
public actor AgentService {
    public typealias ConfirmationHandler = @Sendable (ConfirmationRequest) async -> Bool

    private let llm: (any LocalLLMService)?
    private let registry: ToolRegistry
    private let router: CommandRouter
    private let policy: SecurityPolicy
    private let confirm: ConfirmationHandler
    private let options: @Sendable () -> GenerationOptions
    private let fastRoutingEnabled: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    /// Extra context for the model, e.g. "Focus: Work. Be brief and professional."
    private let situation: @Sendable () async -> String?

    /// Recent user/assistant turns (tool chatter excluded) for follow-up questions.
    private var conversation: [ChatMessage] = []
    private var lastInteraction: Date = .distantPast
    public var maxToolIterations = 4
    public var conversationTTL: TimeInterval = 300

    public init(llm: (any LocalLLMService)?, registry: ToolRegistry, router: CommandRouter,
                policy: SecurityPolicy = SecurityPolicy(),
                options: @escaping @Sendable () -> GenerationOptions = { GenerationOptions() },
                fastRoutingEnabled: @escaping @Sendable () -> Bool = { true },
                now: @escaping @Sendable () -> Date = { Date() },
                situation: @escaping @Sendable () async -> String? = { nil },
                confirm: @escaping ConfirmationHandler) {
        self.llm = llm
        self.registry = registry
        self.router = router
        self.policy = policy
        self.options = options
        self.fastRoutingEnabled = fastRoutingEnabled
        self.now = now
        self.situation = situation
        self.confirm = confirm
    }

    public func resetConversation() {
        conversation.removeAll()
    }

    /// Runs a request. Cancelling the consuming task cancels generation and pending tools.
    public nonisolated func run(_ query: String) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.process(query, emit: { continuation.yield($0) })
                continuation.finish()
            }
            continuation.onTermination = { [llm] _ in
                task.cancel()
                Task { await llm?.cancelGeneration() }
            }
        }
    }

    // MARK: - Processing

    func process(_ rawQuery: String, emit: @escaping @Sendable (AgentEvent) -> Void) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            emit(.failed("I didn't catch that."))
            return
        }
        if now().timeIntervalSince(lastInteraction) > conversationTTL { conversation.removeAll() }
        lastInteraction = now()
        let context = ToolContext(now: now(), originalQuery: query)

        // 1. Deterministic fast path.
        if fastRoutingEnabled(), let call = router.route(query) {
            Log.agent.debug("Fast route → \(call.name, privacy: .public)")
            let result = await execute(call, context: context, emit: emit)
            guard !Task.isCancelled else { return }
            // Some results (web search) are raw material: let the model write the answer.
            if result.status == .success, registry.tool(named: call.name)?.requiresModelAnswer == true,
               let llm, llm.isAvailable {
                do {
                    if !(await llm.isLoaded) {
                        emit(.modelLoading)
                        try await llm.loadModel()
                    }
                    let outcome = try await runModelLoop(query: query, llm: llm, context: context, emit: emit,
                                                         seed: (call, result))
                    guard !Task.isCancelled else { return }
                    remember(query: query, answer: outcome.text)
                    emit(.finished(outcome))
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    Log.agent.error("Answer pass failed: \(error.localizedDescription, privacy: .public)")
                    // Fall through to the tool's own summary and cards.
                }
            }
            let outcome = AgentOutcome(text: result.summary, cards: result.card.map { [$0] } ?? [],
                                       toolNames: [call.name], status: historyStatus(result.status))
            remember(query: query, answer: outcome.text)
            emit(.finished(outcome))
            return
        }

        // 2. Local LLM with tools.
        guard let llm, llm.isAvailable else {
            emit(.failed(LocalModelError.modelNotInstalled(ModelCatalog.defaultLLM.displayName).errorDescription!))
            return
        }
        do {
            if !(await llm.isLoaded) {
                emit(.modelLoading)
                try await llm.loadModel()
            }
            let outcome = try await runModelLoop(query: query, llm: llm, context: context, emit: emit)
            guard !Task.isCancelled else { return }
            remember(query: query, answer: outcome.text)
            emit(.finished(outcome))
        } catch is CancellationError {
            return
        } catch LocalModelError.cancelled {
            return
        } catch {
            guard !Task.isCancelled else { return }
            Log.agent.error("Agent failed: \(error.localizedDescription, privacy: .public)")
            emit(.failed(error.localizedDescription))
        }
    }

    /// `seed` is a tool call the router already ran; the model continues from its result.
    private func runModelLoop(query: String, llm: any LocalLLMService, context: ToolContext,
                              emit: @escaping @Sendable (AgentEvent) -> Void,
                              seed: (call: ToolCall, result: ToolResult)? = nil) async throws -> AgentOutcome {
        var messages: [ChatMessage] = [.system(SystemPrompt.text)] + conversation
        var contextLine = SystemPrompt.contextLine(now: now())
        if let situation = await situation() { contextLine += " [\(situation)]" }
        messages.append(.user(contextLine + "\n" + query))
        // Remembered turns live at 1..<historyEnd; they're the first thing dropped when space runs out.
        var historyEnd = messages.count - 1
        // Several actions in one sentence: keep going after the first tool until the model is done.
        let chained = ChainDetector.isCompound(CommandRouter.normalize(query))

        var cards: [ResultCard] = []
        var toolNames: [String] = []
        var lastResults: [ToolResult] = []
        var allResults: [ToolResult] = []
        if let seed {
            messages.append(.assistant("", toolCalls: [seed.call]))
            messages.append(.tool(seed.call.name, ContextBudget.clip(seed.result.modelPayload, ContextBudget.maxToolPayload)))
            toolNames.append(seed.call.name)
            if let card = seed.result.card { cards.append(card) }
            lastResults = [seed.result]
            allResults = [seed.result]
        }
        var nudged = false
        let tools = registry.schemas

        for iteration in 0..<maxToolIterations {
            emit(.thinking)
            let streamed = StreamBuffer()
            let generation = options()
            ContextBudget.fit(&messages, historyEnd: &historyEnd, toolSchemas: tools, options: generation)
            let raw = try await llm.generate(messages: messages, tools: tools, options: generation) { token in
                let text = streamed.append(token)
                if !ToolCallParser.looksLikeToolCallPrefix(text) {
                    emit(.partialText(ToolCallParser.stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            try Task.checkCancellation()
            let parsed = ToolCallParser.parse(raw)

            if parsed.toolCalls.isEmpty {
                let text = parsed.text.isEmpty ? (lastResults.last?.summary ?? "Done.") : parsed.text
                // Never let the model claim an action it didn't perform through a tool.
                if toolNames.isEmpty, ActionClaimGuard.isUnbacked(answer: text, query: query) {
                    if !nudged, iteration < maxToolIterations - 1 {
                        nudged = true
                        Log.agent.info("Model claimed an action without a tool call; retrying")
                        messages.append(.assistant(parsed.text))
                        messages.append(.user(ActionClaimGuard.nudge))
                        continue
                    }
                    return AgentOutcome(text: ActionClaimGuard.fallback, cards: cards, toolNames: toolNames,
                                        status: .failure, usedModel: true)
                }
                return AgentOutcome(text: text, cards: cards, toolNames: toolNames,
                                    status: lastResults.contains { $0.status == .failure } ? .failure : .success,
                                    usedModel: true)
            }

            messages.append(.assistant(parsed.text, toolCalls: parsed.toolCalls))
            var results: [ToolResult] = []
            var allTerminal = true
            for call in parsed.toolCalls {
                let result = await execute(call, context: context, emit: emit)
                try Task.checkCancellation()
                results.append(result)
                toolNames.append(call.name)
                if let card = result.card { cards.append(card) }
                messages.append(.tool(call.name, ContextBudget.clip(result.modelPayload, ContextBudget.maxToolPayload)))
                let terminal = registry.tool(named: call.name)?.isTerminal ?? false
                if !terminal || result.status == .failure { allTerminal = false }
            }
            lastResults = results
            allResults += results

            // Terminal tools already produce a good final sentence: skip a model pass. A chained
            // request only finishes early when the model already asked for several tools at once.
            let covered = !chained || parsed.toolCalls.count > 1 || toolNames.count > 1
            if (allTerminal && covered) || iteration == maxToolIterations - 1 {
                let text = (chained ? allResults : results).map(\.summary).joined(separator: " ")
                let status: HistoryEntry.Status = results.contains { $0.status == .failure } ? .failure
                    : results.allSatisfy { $0.status == .cancelled } ? .cancelled : .success
                return AgentOutcome(text: text, cards: cards, toolNames: toolNames, status: status, usedModel: true)
            }
        }
        return AgentOutcome(text: lastResults.map(\.summary).joined(separator: " "), cards: cards, toolNames: toolNames,
                            usedModel: true)
    }

    // MARK: - Tool execution

    func execute(_ call: ToolCall, context: ToolContext, emit: @escaping @Sendable (AgentEvent) -> Void) async -> ToolResult {
        guard let tool = registry.tool(named: call.name) else {
            Log.agent.error("Model requested unknown tool \(call.name, privacy: .public)")
            return .failure("There is no tool called \(call.name).")
        }
        let risk = tool.risk(for: call.arguments)
        if policy.requiresConfirmation(risk) {
            let request = ConfirmationRequest(toolName: tool.name, displayName: tool.displayName,
                                              prompt: tool.confirmationPrompt(for: call.arguments), risk: risk)
            emit(.awaitingConfirmation(request))
            let approved = await confirm(request)
            guard approved, !Task.isCancelled else {
                Log.tools.info("User declined \(tool.name, privacy: .public)")
                let result = ToolResult(status: .cancelled, summary: "Okay, I didn't do that.")
                emit(.toolFinished(call, result))
                return result
            }
        }

        emit(.toolStarted(call, displayName: tool.displayName))
        Log.tools.info("Running \(tool.name, privacy: .public) (risk \(risk.displayName, privacy: .public))")
        let result: ToolResult
        do {
            result = try await tool.execute(arguments: call.arguments, context: context)
        } catch {
            Log.tools.error("\(tool.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            // Some errors (AppleScript) echo huge object lists; keep what the user and model see short.
            result = .failure(ContextBudget.clip(error.localizedDescription, 300))
        }
        emit(.toolFinished(call, result))
        return result
    }

    private func remember(query: String, answer: String) {
        conversation.append(.user(query))
        conversation.append(.assistant(ContextBudget.clip(answer, ContextBudget.maxRememberedAnswer)))
        if conversation.count > 6 { conversation.removeFirst(conversation.count - 6) }
    }

    private func historyStatus(_ status: ToolResult.Status) -> HistoryEntry.Status {
        switch status {
        case .success: return .success
        case .failure: return .failure
        case .cancelled: return .cancelled
        }
    }
}

/// Keeps prompts inside the model's context window. Token counts are estimated from
/// characters (about 3.5 per token for Qwen's tokenizer on mixed text), with headroom.
public enum ContextBudget {
    public static let maxToolPayload = 6_000
    public static let maxRememberedAnswer = 800

    public static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    static func estimatedTokens(_ characters: Int) -> Int { Int((Double(characters) / 3.2).rounded(.up)) }

    /// Drops the oldest remembered turns first, then shortens the longest tool results,
    /// until the prompt plus the reply fits. The system prompt and the new request stay.
    public static func fit(_ messages: inout [ChatMessage], historyEnd: inout Int, toolSchemas: [JSONValue],
                           options: GenerationOptions) {
        let toolCharacters = toolSchemas.reduce(0) { $0 + $1.jsonString().count }
        let budget = options.contextLength - options.maxTokens - 256
        func total() -> Int {
            estimatedTokens(toolCharacters + messages.reduce(0) { $0 + $1.content.count + 16 })
        }
        while total() > budget, historyEnd > 1 {
            messages.remove(at: 1)
            historyEnd -= 1
        }
        while total() > budget,
              let index = messages.indices.filter({ messages[$0].role == .tool }).max(by: { messages[$0].content.count < messages[$1].content.count }),
              messages[index].content.count > 400 {
            messages[index].content = clip(messages[index].content, messages[index].content.count / 2)
        }
    }
}

/// Thread-safe accumulator for streamed tokens.
final class StreamBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ token: String) -> String {
        lock.lock(); defer { lock.unlock() }
        text += token
        return text
    }
}

public enum SystemPrompt {
    public static let text = """
    You are IVY, a concise personal macOS assistant running locally on the user's Mac. \
    Respond with the shortest useful answer unless additional detail is necessary. \
    Answers appear in a small overlay under the notch: usually one or two short sentences, no \
    filler, no greetings, no follow-up offers, no markdown headings.
    When the user asks you to perform an action, use an available tool instead of explaining \
    how the user could do it. Never invent reminders, songs, files or results; use tools to look \
    them up. After a tool result, reply briefly based only on that result. \
    If a tool fails, say so briefly.
    For dates and times in tool arguments, repeat the user's own words (for example \
    "tomorrow at 5pm") unless they gave an exact date.
    Never say you did something (opened, played, set, searched, created…) unless a tool \
    result in this conversation confirms it. If no tool fits, say briefly that you can't do it yet.
    Use timer_set for timers and alarms (not reminders). Use browser_search when the user wants \
    a search or page shown in a browser. Use calendar_create to put events in the calendar and \
    reminders_create for to-dos. Use file_search to find files, clipboard for anything about \
    copied text, dictionary for meanings, synonyms and antonyms, mail_search for email, \
    shortcut_run for Home devices, scenes and the user's other Shortcuts, focus for Focus modes \
    (action setup creates the shortcut IVY needs to switch a Focus), low_power_mode for Low Power \
    Mode (never use focus for it) \
    and energy_status for battery health, charging and heat.
    When one message asks for several things ("remind me at 9 to call Alex and add it to my \
    calendar"), call one tool per part. You may emit several <tool_call> blocks in one reply. \
    Once every part is done, reply in one short sentence.
    The context line may name the active Focus; follow its guidance on tone and length.
    If a question needs current or specific facts you're not sure about (news, prices, sports, \
    recent events, people, products, anything after your training data), call web_search first \
    and answer from its results.
    After web_search, answer the actual question with concrete facts, names and numbers from the \
    results. Never reply that you found results or tell the user to check the sources. When the \
    user asks for options or recommendations, list 3-5 specific ones as short "- " lines, each \
    with a few words on why it fits. If the results don't contain the answer, say so briefly.
    """

    public static func contextLine(now: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        return "[Now: \(formatter.string(from: now))]"
    }
}

/// Detects replies that claim an action ("I opened Chrome…") without any tool call.
public enum ActionClaimGuard {
    public static let nudge = """
    [IVY] You didn't call a tool, so nothing actually happened. If the request needs an action \
    or live information, call the right tool now. Otherwise answer without claiming any action.
    """
    public static let fallback = "I couldn't do that. I don't have a tool for it yet."

    static let claimPattern = #"(^|\b)(i('ve| have)? |i'll |i will )?(just )?(opened|opening|launched|launching|started|starting|played|playing|searched|searching|set|created|creating|added|turned|paused|sent|scheduled|closed|deleted|moved|booked|looked up|found and opened)\b|^done\b|\bis (now )?(open|playing|running|set|on|off)\b"#
    static let commandPattern = #"^(please |can you |could you |hey ivy,? )?(open|launch|start|play|pause|search|google|set|create|make|remind|add|turn|switch|close|quit|send|call|text|email|delete|move|book|schedule|show me|go to|find me|download|install|run)\b"#
    static let explainPattern = #"\b(you can|you could|to do (this|that|so)|follow these|steps?:|click|navigate to|go to the)\b"#

    public static func isUnbacked(answer: String, query: String) -> Bool {
        let text = answer.lowercased()
        let request = query.lowercased().trimmingCharacters(in: .whitespaces)
        let claims = text.range(of: claimPattern, options: .regularExpression) != nil
        let isCommand = request.range(of: commandPattern, options: .regularExpression) != nil
        let explains = text.range(of: explainPattern, options: .regularExpression) != nil
        if isCommand && (claims || explains) { return true }
        // Past-tense first-person claims are suspicious even for non-command phrasing.
        return text.range(of: #"^(i('ve| have)? )(opened|launched|started|played|searched|set|created|added|turned on|turned off)\b"#,
                          options: .regularExpression) != nil
    }
}
