import AppKit
import IVYCore

// MARK: - Files

struct FileSearchTool: IVYTool {
    let service: FileSearchService
    let name = ToolName.fileSearch
    let description = "Find files or folders on this Mac with Spotlight by part of the name, type and/or when they were modified."
    let displayName = "Spotlight"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [
            ToolParameter("name", .string, "Words in the file name, e.g. 'invoice' or 'tax return'."),
            ToolParameter("kind", .string, "File type.", enumValues: FileKind.allCases.map(\.rawValue)),
            ToolParameter("modified", .string, "When it was last changed.", enumValues: DateWindow.allCases.map(\.rawValue)),
            ToolParameter("folder", .string, "Only search this folder, e.g. 'downloads' or '~/Projects'."),
        ]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let request = FileSearchRequest(
            name: arguments.string("name").map { String($0.prefix(80)) },
            kind: arguments.string("kind").flatMap(FileKind.from(word:)) ?? .any,
            modified: arguments.string("modified").flatMap(DateWindow.parse),
            folder: arguments.string("folder"))
        guard request.isSpecific else { throw ToolError.missingArgument("name") }
        if let folder = request.folder, FilePathResolver.resolve(folder) == nil {
            return .failure("I couldn't find the folder \(folder).")
        }
        let hits = await service.search(request, now: context.now)
        let summary = request.summary(count: hits.count)
        return ToolResult(summary: summary,
                          data: ["files": .array(hits.prefix(8).map { .string(($0.url.path as NSString).abbreviatingWithTildeInPath) })],
                          card: hits.isEmpty ? nil : .files(title: "Files", items: hits),
                          historyTitle: "File Search")
    }
}

// MARK: - Clipboard

struct ClipboardTool: IVYTool {
    let text: LLMTextService
    let name = ToolName.clipboard
    let description = "Work with the text on the clipboard: show, summarize, bullet points, action items, extract lists/emails/links, convert to JSON/CSV/table, fix grammar, shorten, change tone, translate or change case."
    let displayName = "Clipboard"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [
            ToolParameter("action", .string, "What to do with the clipboard text.", required: true,
                          enumValues: ClipboardAction.allCases.map(\.rawValue)),
            ToolParameter("detail", .string, "Target language for translate, or the request for custom."),
            ToolParameter("copy_result", .boolean, "Put the result on the clipboard (only when the user asks)."),
        ]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let raw = try arguments.requiredString("action").lowercased()
        guard let action = ClipboardAction(rawValue: raw) else { throw ToolError.invalidArgument("action", "unknown action") }
        guard let input = await MainActor.run(body: { ClipboardService.read() }) else {
            return .failure("Your clipboard doesn't contain any text.")
        }
        let detail = arguments.string("detail").map { String($0.prefix(200)) }
        let words = input.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count

        let output: String
        if let exact = ClipboardTransforms.deterministic(action, text: input) {
            output = exact
        } else if action.usesModel {
            guard text.isAvailable(for: action == .translate ? .translation : action == .fixGrammar ? .grammar : .writing) else {
                return .failure("Configure an AI model in Settings ▸ AI before rewriting the clipboard.")
            }
            // Stream the result into a card while the model writes it.
            let title = action.title
            let reply = try await text.complete(system: ClipboardTransforms.systemPrompt,
                                                user: ClipboardTransforms.userPrompt(action: action, detail: detail, text: input),
                                                task: action == .translate ? .translation : action == .fixGrammar ? .grammar : .writing,
                                                maxTokens: action == .summarize || action == .shorten ? 400 : 1200) { partial in
                context.preview(.text(title: title, body: ClipboardTransforms.cleanModelOutput(partial)))
            }
            output = ClipboardTransforms.cleanModelOutput(reply)
        } else {
            output = input
        }
        guard !output.isEmpty else {
            let what = action == .extractEmails ? "email addresses" : action == .extractLinks ? "links" : "anything to extract"
            return ToolResult(summary: "I didn't find \(what) on your clipboard.", historyTitle: "Clipboard")
        }

        let copy = arguments.bool("copy_result") == true && action != .show
        if copy { await MainActor.run { ClipboardService.write(output) } }
        let truncated = input.count > ClipboardTransforms.maxModelCharacters && action.usesModel
        let summary: String
        switch action {
        case .show: summary = "Your clipboard has \(words) word\(words == 1 ? "" : "s")."
        case .wordCount: summary = output + "."
        case .summarize where output.count <= 220 && !copy: summary = output
        default:
            summary = "\(action.title) of your clipboard\(copy ? ", copied" : "")."
                + (truncated ? " I only used the first \(ClipboardTransforms.maxModelCharacters / 1000)k characters." : "")
        }
        let card: ResultCard? = action == .wordCount || (action == .summarize && summary == output)
            ? nil : .text(title: action.title, body: String(output.prefix(6000)))
        return ToolResult(summary: summary, card: card, historyTitle: "Clipboard")
    }
}

// MARK: - Dictionary

struct DictionaryTool: IVYTool {
    let text: LLMTextService
    let name = ToolName.dictionary
    let description = "Look up a word offline: its definition, synonyms or antonyms."
    let displayName = "Dictionary"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [
            ToolParameter("word", .string, "The word or short phrase.", required: true),
            ToolParameter("mode", .string, "define (default), synonyms or antonyms", enumValues: DictionaryMode.allCases.map(\.rawValue)),
        ]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        guard let word = WordLookup.cleanWord(try arguments.requiredString("word")) else {
            throw ToolError.invalidArgument("word", "use a single word or short phrase")
        }
        let mode = arguments.string("mode").flatMap { DictionaryMode(rawValue: $0.lowercased()) } ?? .define
        var result = DefinitionResult(word: word, definition: SystemDictionary.definition(of: word))

        switch mode {
        case .define:
            if result.definition == nil, text.isAvailable(for: .definitions) {
                let reply = try await text.complete(system: WordLookup.definitionSystemPrompt,
                                                    user: "Define \"\(word)\".", task: .definitions, maxTokens: 80)
                result.definition = reply.nilIfBlank.map { WordLookup.cleanDefinition($0) }
                result.fromSystemDictionary = false
            }
        case .synonyms, .antonyms:
            guard text.isAvailable(for: .definitions) else { return .failure("Configure an AI model in Settings ▸ AI before listing \(mode.rawValue).") }
            let reply = try await text.complete(system: WordLookup.listSystemPrompt,
                                                user: WordLookup.listPrompt(mode: mode, word: word), task: .definitions, maxTokens: 80)
            let list = WordLookup.parseList(reply, excluding: word)
            if mode == .synonyms { result.synonyms = list } else { result.antonyms = list }
        }
        let summary = WordLookup.summary(for: result, mode: mode)
        let found = result.definition != nil || !result.synonyms.isEmpty || !result.antonyms.isEmpty
        return ToolResult(status: found ? .success : .failure, summary: summary,
                          card: found ? .definition(result) : nil, historyTitle: "Dictionary")
    }
}

// MARK: - Mail

struct MailSearchTool: IVYTool {
    let service: MailService
    let name = ToolName.mailSearch
    let description = "Check the Apple Mail inbox: new/unread mail, mail from a sender, or search subjects. Reads only sender, subject and date."
    let displayName = "Mail"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [
            ToolParameter("from", .string, "Sender name or address."),
            ToolParameter("query", .string, "Words in the subject."),
            ToolParameter("unread_only", .boolean, "Only unread messages (for 'new mail')."),
            ToolParameter("days", .integer, "How many days back to look (default 14, or 60 when searching)."),
        ]
    }

    /// "A, B or C".
    static func list(_ items: [String]) -> String {
        items.count <= 1 ? (items.first ?? "") : items.dropLast().joined(separator: ", ") + " or " + items.last!
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        guard service.isInstalled else { return .failure("Apple Mail isn't installed.") }
        try await service.ensureRunning()
        let from = arguments.string("from").map { String($0.prefix(80)) }
        let query = arguments.string("query").map { String($0.prefix(80)) }
        let unreadOnly = arguments.bool("unread_only") ?? false
        // Searching a sender or subject looks further back than "any new mail?".
        let days = arguments.int("days").map { max(1, min($0, 365)) } ?? (from != nil || query != nil ? 60 : 14)
        let inbox = try await service.recentInbox(days: days)
        let items = MailFilter.filter(inbox, from: from, query: query, unreadOnly: unreadOnly)
        // "Alex" matched several people: ask instead of mixing their mail together.
        if let from, query == nil, let names = MailFilter.ambiguousSenders(in: items, for: from) {
            return .question("Which \(from.capitalizedFirst) do you mean: \(Self.list(names))?", historyTitle: "Mail")
        }
        let title = from.map { "From \($0.capitalizedFirst)" } ?? query.map { "“\($0)”" } ?? (unreadOnly ? "Unread" : "Inbox")
        return ToolResult(summary: MailFilter.summary(for: items, from: from, query: query, unreadOnly: unreadOnly),
                          data: ["messages": .array(items.prefix(8).map {
                              .string("\($0.senderName): \($0.subject) (\($0.date.formatted(date: .abbreviated, time: .shortened)))")
                          })],
                          card: items.isEmpty ? nil : .mail(title: title, items: items),
                          historyTitle: "Mail")
    }
}

// MARK: - Calendar

struct CalendarCreateTool: IVYTool {
    let service: CalendarService
    var undo: UndoStore? = nil
    let name = ToolName.calendarCreate
    let description = "Add an event to the user's calendar."
    let displayName = "Calendar"
    let baseRisk = RiskLevel.medium
    var parameters: [ToolParameter] {
        [
            ToolParameter("title", .string, "Event title, e.g. 'Call Alex'.", required: true),
            ToolParameter("start", .string, "When, in the user's own words (e.g. 'tomorrow at 9') or ISO-8601.", required: true),
            ToolParameter("duration", .string, "Length in the user's words, e.g. '30 minutes'. Default one hour."),
            ToolParameter("location", .string, "Optional place."),
        ]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let title = try arguments.requiredString("title")
        guard title.count <= 200 else { throw ToolError.invalidArgument("title", "too long") }
        let rawStart = try arguments.requiredString("start")
        guard let start = NaturalDateParser.parse(rawStart, now: context.now) else {
            throw ToolError.invalidArgument("start", "I couldn't understand the time '\(rawStart)'.")
        }
        let duration = arguments.string("duration").flatMap { DurationParser.seconds(in: $0) }
        let end = duration.map { start.date.addingTimeInterval(min($0, 24 * 3600)) }
        let event = try await service.create(title: title, start: start.date, end: start.hasTime ? end : nil,
                                             allDay: !start.hasTime, location: arguments.string("location"))
        if let undo { await undo.add(label: "Remove event: " + event.title) { try await service.undoCreation(event) } }
        let when = RemindersCreateTool.describe(event.start, hasTime: !event.isAllDay)
        return ToolResult(summary: "Added “\(event.title)” to your calendar \(when).",
                          data: ["event": ["id": .string(event.id), "title": .string(event.title), "start": .string(event.start.ISO8601Format()), "end": .string(event.end.ISO8601Format())]],
                          card: .events(title: "New Event", items: [event]), historyTitle: "New Event")
    }
}

// MARK: - Shortcuts & Home

struct ShortcutRunTool: IVYTool {
    let service: ShortcutsService
    let name = ToolName.shortcutRun
    let displayName = "Shortcuts"
    let baseRisk = RiskLevel.medium

    /// Lists the user's shortcuts so the model can pick a real one (HomeKit scenes, lights…).
    var description: String {
        let names = service.cachedShortcuts.prefix(40).map(\.name)
        let list = names.isEmpty ? "" : " Available: \(names.joined(separator: "; "))."
        return "Run one of the user's Shortcuts, e.g. Home scenes, lights or thermostat (macOS has no direct HomeKit access).\(list)"
    }

    var parameters: [ToolParameter] {
        [
            ToolParameter("name", .string, "The shortcut's name.", required: true),
            ToolParameter("input", .string, "Optional input for the shortcut, e.g. '50' for a brightness or '21' for a temperature."),
        ]
    }

    func risk(for arguments: [String: JSONValue]) -> RiskLevel {
        let name = arguments.string("name") ?? ""
        let matched = ShortcutMatcher.best(for: name, in: service.cachedShortcuts)?.name ?? name
        return ShortcutMatcher.isSensitive(matched) ? .high : baseRisk
    }

    func confirmationPrompt(for arguments: [String: JSONValue]) -> String {
        let name = arguments.string("name") ?? "this shortcut"
        let matched = ShortcutMatcher.best(for: name, in: service.cachedShortcuts)?.name ?? name
        return "Run the shortcut “\(matched)”\(arguments.string("input").map { " with “\($0)”" } ?? "")?"
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let requested = try arguments.requiredString("name")
        let shortcuts = await service.list()
        guard !shortcuts.isEmpty else {
            return .failure("You don't have any Shortcuts yet. Create one in the Shortcuts app (for example for a Home scene) and ask again.")
        }
        if let options = ShortcutMatcher.ambiguous(for: requested, in: shortcuts) {
            return .question("Which shortcut: \(MailSearchTool.list(options.map { "“\($0.name)”" }))?", historyTitle: "Shortcut")
        }
        guard let shortcut = ShortcutMatcher.best(for: requested, in: shortcuts) else {
            let some = shortcuts.prefix(5).map(\.name).joined(separator: ", ")
            return .failure("I couldn't find a shortcut called “\(requested)”. You have: \(some).")
        }
        let input = arguments.string("input").map { String($0.prefix(200)) }
        let output = try await service.run(shortcut, input: input)
        let summary = output.map { "\(shortcut.name): \($0)" } ?? "Ran “\(shortcut.name)”\(input.map { " with \($0)" } ?? "")."
        return ToolResult(summary: summary, historyTitle: "Shortcut")
    }
}

// MARK: - Focus

struct FocusTool: IVYTool {
    let focus: FocusService
    let shortcuts: ShortcutsService
    let name = ToolName.focus
    let description = "Focus modes only (Do Not Disturb, Sleep, Work, Personal…): check which is on, turn one on or off, or set up the shortcut IVY needs to switch it. Not for Low Power Mode or other settings."
    let displayName = "Focus"
    let baseRisk = RiskLevel.medium
    var parameters: [ToolParameter] {
        [
            ToolParameter("action", .string, "status, on, off, or setup (only create the shortcut)", required: true,
                          enumValues: ["status", "on", "off", "setup"]),
            ToolParameter("name", .string, "Focus name, e.g. 'Sleep', 'Work' or 'Do Not Disturb'."),
        ]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let action = try arguments.requiredString("action").lowercased()
        if action == "status" {
            switch focus.current(maxAge: 0) {
            case .on(let name): return ToolResult(summary: "\(name) Focus is on.", historyTitle: "Focus")
            case .off: return ToolResult(summary: "No Focus is on.", historyTitle: "Focus")
            case .unavailable:
                return .failure("I can't see your Focus yet. Give IVY Full Disk Access in System Settings ▸ Privacy & Security to let it read your Focus.")
            }
        }
        let configured = focus.modeIdentifiers()
        let turnOn = action != "off"
        var mode: String?
        var identifier: String?
        if let requested = arguments.string("name") {
            guard let resolved = FocusParser.resolve(requested, configured: configured, localized: FocusService.localizedModeNames) else {
                let known = configured.isEmpty ? focus.modeNames() : configured.values.sorted()
                return .failure("“\(requested)” isn't one of your Focus modes. You have: \(known.joined(separator: ", ")).")
            }
            (mode, identifier) = (resolved.name, resolved.identifier)
        } else if turnOn {
            if action == "setup" { throw ToolError.missingArgument("name") }
            (mode, identifier) = FocusParser.resolve("Do Not Disturb", configured: configured, localized: FocusService.localizedModeNames) ?? ("Do Not Disturb", nil)
        } else if let active = focus.activeName {
            // "Turn off focus" without a name ends the active one.
            (mode, identifier) = FocusParser.resolve(active, configured: configured, localized: FocusService.localizedModeNames) ?? (active, nil)
        }

        let list = await shortcuts.list()
        var shortcut = ShortcutMatcher.focusShortcut(named: mode, on: turnOn, in: list)
        let shortcutName = ShortcutBuilder.focusShortcutName(focus: mode, on: turnOn)
        if action == "setup", let shortcut {
            return ToolResult(summary: "You already have “\(shortcut.name)”. Just ask me to turn on \(mode ?? "a") Focus.", historyTitle: "Focus")
        }
        if shortcut == nil {
            // macOS only lets Shortcuts switch Focus, so IVY offers to add a one-action shortcut.
            if turnOn, identifier == nil {
                return .failure("I don't know the system ID of your \(mode ?? "") Focus. Give IVY Full Disk Access so it can read your Focus modes, then ask again.")
            }
            let workflow = try ShortcutBuilder.focusWorkflow(focus: mode, identifier: identifier, on: turnOn)
            switch try await shortcuts.install(name: shortcutName, workflow: workflow) {
            case .added(let added): shortcut = added
            case .waiting:
                return ToolResult(summary: "Click “Add Shortcut” in the Shortcuts window to add “\(shortcutName)”, then ask me again.",
                                  historyTitle: "Focus")
            }
        }
        guard let shortcut else { return .failure("I couldn't find the Focus shortcut.") }
        if action == "setup" {
            return ToolResult(summary: "Added “\(shortcut.name)”. Ask me to turn on \(mode ?? "your") Focus any time.", historyTitle: "Focus")
        }
        _ = try await shortcuts.run(shortcut, input: nil)
        focus.invalidate()
        // Check it really switched when IVY can read the Focus state (Full Disk Access).
        try? await Task.sleep(for: .milliseconds(800))
        switch focus.current(maxAge: 0) {
        case .on(let active) where !turnOn || (mode.map { active.caseInsensitiveCompare($0) != .orderedSame } ?? false):
            return .failure("I ran “\(shortcut.name)”, but \(active) Focus is on.")
        case .off where turnOn:
            return .failure("I ran “\(shortcut.name)”, but no Focus is on. Check the shortcut in the Shortcuts app.")
        default:
            break
        }
        let summary = turnOn ? "\(mode ?? "Do Not Disturb") Focus is on." : "\(mode.map { "\($0) Focus" } ?? "Focus") is off."
        return ToolResult(summary: summary, historyTitle: "Focus")
    }
}

// MARK: - Low Power Mode

struct LowPowerModeTool: IVYTool {
    let name = ToolName.lowPowerMode
    let description = "Turn Low Power Mode on or off, or check whether it's on."
    let displayName = "Low Power Mode"
    let baseRisk = RiskLevel.medium
    var parameters: [ToolParameter] {
        [ToolParameter("action", .string, "on, off or status", required: true, enumValues: ["on", "off", "status"])]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let action = try arguments.requiredString("action").lowercased()
        let isOn = ProcessInfo.processInfo.isLowPowerModeEnabled
        if action == "status" {
            return ToolResult(summary: "Low Power Mode is \(isOn ? "on" : "off").", historyTitle: "Low Power Mode")
        }
        let turnOn = action == "on"
        if turnOn == isOn {
            return ToolResult(summary: "Low Power Mode is already \(isOn ? "on" : "off").", historyTitle: "Low Power Mode")
        }
        // Shortcuts' Set Low Power Mode action isn't supported on the Mac; `pmset` is the only
        // way and needs an administrator. macOS asks for the password (or Touch ID) itself.
        // Fixed command, no user or model text involved.
        let script = "do shell script \"/usr/bin/pmset -a lowpowermode \(turnOn ? 1 : 0)\" with administrator privileges"
        do {
            _ = try await AppleScriptRunner.shared.run(script)
        } catch let error as AppleScriptRunner.ScriptError where error.code == -128 {
            return ToolResult(status: .cancelled, summary: "Okay, I left Low Power Mode \(isOn ? "on" : "off").",
                              historyTitle: "Low Power Mode")
        }
        try? await Task.sleep(for: .milliseconds(400))
        let now = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard now == turnOn else {
            return .failure("Low Power Mode is still \(now ? "on" : "off"). You can switch it in System Settings ▸ Battery.")
        }
        return ToolResult(summary: "Low Power Mode is \(turnOn ? "on" : "off").", historyTitle: "Low Power Mode")
    }
}

// MARK: - Energy

struct EnergyTool: IVYTool {
    let monitor: EnergyMonitor
    let llm: MLXLLMService
    let name = ToolName.energyStatus
    let description = "Battery health, cycle count, temperature, charging advice and whether the Mac is running hot."
    let displayName = "Battery"
    let baseRisk = RiskLevel.low
    let parameters: [ToolParameter] = []

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        var snapshot = await MainActor.run {
            monitor.refresh()
            return monitor.snapshot
        }
        snapshot.modelLoaded = await llm.isLoaded
        snapshot.modelName = llm.descriptor.displayName
        return ToolResult(summary: EnergyAdvisor.summary(for: snapshot), card: .energy(snapshot), historyTitle: "Battery & Energy")
    }
}

// MARK: - Editing an observed event

struct CalendarUpdateTool: IVYTool {
    let service: CalendarService
    let undo: UndoStore
    let name = ToolName.calendarUpdate
    let description = "Move a previously found calendar event by its exact ID. Preserve its time when only a day is given. Use offset for 'an hour later'."
    let displayName = "Move Calendar Event"
    let baseRisk = RiskLevel.high
    var parameters: [ToolParameter] {
        [ToolParameter("id", .string, "Exact ID from calendar_events or calendar_create.", required: true),
         ToolParameter("start", .string, "New day or time in the user's words, or ISO-8601."),
         ToolParameter("offset_minutes", .integer, "Shift the existing event by this many minutes. Negative moves it earlier."),
         ToolParameter("duration", .string, "Optional new duration, e.g. 'one hour'.")]
    }
    func confirmationPrompt(for arguments: [String: JSONValue]) -> String {
        "Change this calendar event's time?\n" + JSONValue.object(arguments).jsonString()
    }
    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let id = try arguments.requiredString("id")
        guard id.count <= 500 else { throw ToolError.invalidArgument("id", "invalid event identifier") }
        let existing = try await service.event(id: id)
        var start = existing.start
        if let raw = arguments.string("start") {
            guard let parsed = NaturalDateParser.parse(raw, now: context.now) else { throw ToolError.invalidArgument("start", "unrecognized date") }
            start = parsed.date
            if !parsed.hasTime && !existing.isAllDay {
                let time = Calendar.current.dateComponents([.hour, .minute, .second], from: existing.start)
                guard let combined = Calendar.current.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: start) else { throw ToolError.invalidArgument("start", "invalid time") }
                start = combined
            }
        } else if let offset = arguments.int("offset_minutes"), (-10_080...10_080).contains(offset), offset != 0 {
            start = start.addingTimeInterval(Double(offset) * 60)
        } else { throw ToolError.invalidArgument("start", "provide a new time or an offset") }
        let duration: TimeInterval?
        if let raw = arguments.string("duration") {
            guard let seconds = DurationParser.seconds(in: raw), seconds > 0, seconds <= 86400 else { throw ToolError.invalidArgument("duration", "use a duration up to one day") }
            duration = seconds
        } else { duration = nil }
        let changed = try await service.update(id: id, start: start, duration: duration)
        await undo.add(label: "Restore event time: " + changed.before.title) { try await service.restore(changed.before, ifUnchanged: changed.after) }
        return ToolResult(summary: "Moved “\(changed.after.title)” to \(changed.after.start.formatted(date: .abbreviated, time: .shortened)).",
            data: ["event": ["id": .string(changed.after.id), "title": .string(changed.after.title), "start": .string(changed.after.start.formatted(.iso8601)), "end": .string(changed.after.end.formatted(.iso8601))]],
            card: .events(title: "Updated Event", items: [changed.after]), historyTitle: "Updated Event")
    }
}
