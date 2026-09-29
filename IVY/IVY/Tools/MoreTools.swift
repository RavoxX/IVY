import AppKit
import IVYCore

// MARK: - Browser

/// Shows a Google search (or a URL) in a browser — "open Chrome and search for the Eiffel Tower".
struct BrowserSearchTool: IVYTool {
    let launcher: AppLauncher
    let name = ToolName.browserSearch
    let description = "Open a web search in the user's browser (optionally a specific browser like Chrome or Safari)."
    let displayName = "Browser"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [
            ToolParameter("query", .string, "What to search for.", required: true),
            ToolParameter("browser", .string, "Browser app name, e.g. 'Google Chrome' or 'Safari'. Omit for the default browser."),
        ]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let query = try arguments.requiredString("query")
        guard query.count <= 300 else { throw ToolError.invalidArgument("query", "too long") }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw ToolError.invalidArgument("query", "invalid") }
        let browser = try await BrowserOpener.open(url, browser: arguments.string("browser"), launcher: launcher)
        return ToolResult(summary: "Searching Google for “\(query)”\(browser.map { " in \($0)" } ?? "").",
                          card: .link(title: query, url: url), historyTitle: "Browser Search")
    }
}

enum BrowserOpener {
    /// Opens `url` in a named browser (validated against installed apps) or the default one.
    /// Returns the browser name used, and throws if nothing could be opened.
    static func open(_ url: URL, browser: String?, launcher: AppLauncher) async throws -> String? {
        if let browser, !browser.isEmpty {
            guard let app = launcher.resolve(browser) else {
                throw ToolError.unavailable("\(browser) isn't installed.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app.url, configuration: configuration)
            return app.name
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { throw ToolError.failed("I couldn't open the browser.") }
        return nil
    }
}

// MARK: - Web search (answers)

struct WebSearchTool: IVYTool {
    let settings: SettingsStore
    let name = ToolName.webSearch
    let description = "Search the web in the background for current or factual information, then answer from the results."
    let displayName = "Web"
    let baseRisk = RiskLevel.low
    let isTerminal = false
    let requiresModelAnswer = true
    var parameters: [ToolParameter] {
        [ToolParameter("query", .string, "A concise search query.", required: true)]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        guard settings.bool(.webSearchEnabled) else {
            return .failure("Web search is turned off in IVY Settings.")
        }
        let query = try arguments.requiredString("query")
        let result = try await WebSearchService().search(query)
        var data: [String: JSONValue] = [
            "results": .array(result.links.map { link in
                ["title": .string(link.title), "snippet": .string(String(link.snippet.prefix(300))),
                 "source": .string(link.url.host ?? "")]
            }),
        ]
        if let excerpt = result.excerpt { data["top_page_excerpt"] = .string(excerpt) }
        return ToolResult(summary: "Found \(result.links.count) web results for “\(query)”.", data: .object(data),
                          card: .sources(query: query, items: result.links), historyTitle: "Web Search")
    }
}

// MARK: - Timers

struct TimerSetTool: IVYTool {
    let timers: TimerService
    let name = ToolName.timerSet
    let description = "Start a countdown timer (duration) or set an alarm (clock time). Shown on the notch."
    let displayName = "Timer"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [
            ToolParameter("duration", .string, "Timer length in the user's words, e.g. '10 minutes'."),
            ToolParameter("at", .string, "Alarm time in the user's words, e.g. '7am' or 'tomorrow at 6:30'."),
            ToolParameter("label", .string, "Optional name, e.g. 'pasta'."),
        ]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let label = arguments.string("label")
        if let raw = arguments.string("duration"), let seconds = DurationParser.seconds(in: raw) {
            guard seconds >= 1, seconds <= 24 * 3600 else { throw ToolError.invalidArgument("duration", "must be under 24 hours") }
            let timer = await timers.start(duration: seconds, label: label)
            let name = label.map { " \($0)" } ?? ""
            return ToolResult(summary: "\(DurationParser.describe(seconds).capitalizedFirst)\(name) timer started.",
                              card: .timers([timer]), historyTitle: "Timer")
        }
        if let raw = arguments.string("at") ?? arguments.string("duration"),
           var parsed = NaturalDateParser.parse(raw, now: context.now) {
            if !parsed.hasTime { throw ToolError.invalidArgument("at", "needs a time of day") }
            if parsed.date <= context.now { parsed.date = Calendar.current.date(byAdding: .day, value: 1, to: parsed.date) ?? parsed.date }
            let timer = await timers.alarm(at: parsed.date, label: label)
            let time = parsed.date.formatted(date: .omitted, time: .shortened)
            let day = Calendar.current.isDateInToday(parsed.date) ? "" : Calendar.current.isDateInTomorrow(parsed.date) ? " tomorrow" : ""
            return ToolResult(summary: "Alarm set for \(time)\(day).", card: .timers([timer]), historyTitle: "Alarm")
        }
        throw ToolError.missingArgument("duration")
    }
}

struct TimerListTool: IVYTool {
    let timers: TimerService
    let name = ToolName.timerList
    let description = "List running timers and alarms with the time left."
    let displayName = "Timer"
    let baseRisk = RiskLevel.low
    let parameters: [ToolParameter] = []

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let running = await timers.timers
        guard let first = running.first else { return ToolResult(summary: "No timers are running.") }
        let summary = running.count == 1
            ? "\(DurationParser.countdown(first.remaining())) left on your \(first.title.lowercased())."
            : "\(running.count) timers running; the next ends in \(DurationParser.countdown(first.remaining()))."
        return ToolResult(summary: summary, card: .timers(running), historyTitle: "Timer")
    }
}

struct TimerCancelTool: IVYTool {
    let timers: TimerService
    let name = ToolName.timerCancel
    let description = "Cancel timers/alarms (all, or those matching a label) and silence a ringing one."
    let displayName = "Timer"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [ToolParameter("label", .string, "Only cancel timers with this label.")]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let count = await MainActor.run {
            timers.stopRinging()
            return timers.cancel(label: arguments.string("label"))
        }
        return ToolResult(summary: count == 0 ? "No timers to cancel." : "Cancelled \(count == 1 ? "the timer" : "\(count) timers").",
                          historyTitle: "Timer")
    }
}

// MARK: - Weather & calendar

struct WeatherTool: IVYTool {
    let settings: SettingsStore
    let name = ToolName.weather
    let description = "Current weather and today's/tomorrow's forecast for a place (default: the user's city)."
    let displayName = "Weather"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [
            ToolParameter("location", .string, "City name. Omit for the user's location."),
            ToolParameter("day", .string, "today or tomorrow", enumValues: ["today", "tomorrow"]),
        ]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        guard settings.bool(.webSearchEnabled) else { return .failure("Online features are turned off in IVY Settings.") }
        let tomorrow = arguments.string("day")?.lowercased() == "tomorrow"
        let report = try await WeatherService().report(location: arguments.string("location"), tomorrow: tomorrow)
        let temp = Int(report.temperature.rounded())
        var summary = tomorrow
            ? "Tomorrow in \(report.location): \(report.condition.lowercased()), up to \(temp)\(report.unit)."
            : "\(report.location): \(temp)\(report.unit), \(report.condition.lowercased()). High \(Int(report.high.rounded()))°, low \(Int(report.low.rounded()))°."
        if let rain = report.precipitationChance, rain >= 40 { summary += " \(rain)% chance of rain." }
        return ToolResult(summary: summary, card: .weather(report), historyTitle: "Weather")
    }
}

struct CalendarTool: IVYTool {
    let service: CalendarService
    let name = ToolName.calendarEvents
    let description = "List calendar events for today, tomorrow or the next 7 days."
    let displayName = "Calendar"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [ToolParameter("scope", .string, "today (default), tomorrow or week", enumValues: ["today", "tomorrow", "week"])]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let scope = arguments.string("scope")?.lowercased() ?? "today"
        let events = try await service.events(scope: scope, now: context.now)
        let when = scope == "week" ? "this week" : scope
        guard !events.isEmpty else { return ToolResult(summary: "Nothing on your calendar \(when).", historyTitle: "Calendar") }
        let list = events.prefix(3).map { event in
            event.isAllDay ? event.title : "\(event.title) at \(event.start.formatted(date: .omitted, time: .shortened))"
        }.joined(separator: ", ")
        let noun = events.count == 1 ? "event" : "events"
        return ToolResult(summary: "You have \(ReminderTransforms.countWord(events.count)) \(noun) \(when): \(list).",
                          card: .events(title: scope == "week" ? "This Week" : scope.capitalized, items: events),
                          historyTitle: "Calendar")
    }
}

// MARK: - System

struct SystemVolumeTool: IVYTool {
    let name = ToolName.systemVolume
    let description = "Change the Mac's output volume: up, down, set to a level, mute or unmute."
    let displayName = "Volume"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [
            ToolParameter("action", .string, "What to do.", required: true, enumValues: ["up", "down", "set", "mute", "unmute"]),
            ToolParameter("level", .integer, "0-100, for set."),
        ]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let action = try arguments.requiredString("action").lowercased()
        let runner = AppleScriptRunner.shared
        // Standard Additions run in-process: no Automation permission needed.
        switch action {
        case "mute", "unmute":
            let mute = action == "mute"
            _ = try await runner.run("set volume \(mute ? "with" : "without") output muted")
            let muted = try await runner.run("output muted of (get volume settings)").booleanValue
            guard muted == mute else { return .failure("The Mac is still \(muted ? "muted" : "unmuted").") }
            return ToolResult(summary: mute ? "Muted." : "Sound is on.")
        default:
            let current = Int(try await runner.run("output volume of (get volume settings)").int32Value)
            var target: Int
            switch action {
            case "set":
                guard let level = arguments.int("level") else { throw ToolError.missingArgument("level") }
                target = level
            case "down": target = current - 12
            default: target = current + 12
            }
            target = max(0, min(100, target))
            _ = try await runner.run("set volume output volume \(target) without output muted")
            // Report the level macOS actually applied (it rounds to its own steps).
            let applied = Int(try await runner.run("output volume of (get volume settings)").int32Value)
            return ToolResult(summary: "Volume \(applied)%.")
        }
    }
}

struct DarkModeTool: IVYTool {
    let name = ToolName.darkMode
    let description = "Switch macOS between dark and light appearance."
    let displayName = "Appearance"
    let baseRisk = RiskLevel.medium
    var parameters: [ToolParameter] {
        [ToolParameter("mode", .string, "dark, light or toggle", required: true, enumValues: ["dark", "light", "toggle"])]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let mode = try arguments.requiredString("mode").lowercased()
        let value: String
        switch mode {
        case "dark": value = "true"
        case "light": value = "false"
        case "toggle": value = "not dark mode"
        default: throw ToolError.invalidArgument("mode", "use dark, light or toggle")
        }
        do {
            _ = try await AppleScriptRunner.shared.run(
                "tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)")
        } catch let error as AppleScriptRunner.ScriptError where error.isPermissionDenied {
            throw ToolError.permissionDenied("Automation (IVY → System Events)")
        }
        // Ask System Events what's actually set now (the app's own appearance can lag).
        let isDark = (try? await AppleScriptRunner.shared.run(
            "tell application \"System Events\" to tell appearance preferences to get dark mode"))?.booleanValue
        if let isDark, mode != "toggle", isDark != (mode == "dark") {
            return .failure("Dark mode didn't change.")
        }
        let resolved = isDark.map { $0 ? "dark" : "light" } ?? mode
        return ToolResult(summary: "\(resolved.capitalized) mode is on.")
    }
}

struct SystemInfoTool: IVYTool {
    let name = ToolName.systemInfo
    let description = "Battery level, free disk space, current time or date on this Mac."
    let displayName = "System"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [ToolParameter("kind", .string, "What to report.", required: true, enumValues: ["battery", "disk", "time", "date"])]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        switch try arguments.requiredString("kind").lowercased() {
        case "battery":
            guard let reading = await MainActor.run(body: { BatteryMonitor.read() }) else {
                return ToolResult(summary: "This Mac has no battery.")
            }
            let state = reading.isCharging ? ", charging" : reading.isPluggedIn ? ", plugged in" : ""
            return ToolResult(summary: "Battery is at \(reading.percent)%\(state).")
        case "disk":
            let values = try URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            let free = ByteCountFormatter.string(fromByteCount: values.volumeAvailableCapacityForImportantUsage ?? 0, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(values.volumeTotalCapacity ?? 0), countStyle: .file)
            return ToolResult(summary: "\(free) free of \(total).")
        case "date":
            return ToolResult(summary: "Today is \(context.now.formatted(date: .complete, time: .omitted)).")
        default:
            return ToolResult(summary: "It's \(context.now.formatted(date: .omitted, time: .shortened)).")
        }
    }
}

struct CalculatorTool: IVYTool {
    let name = ToolName.calculate
    let description = "Evaluate an arithmetic expression exactly (+ - * / ^ %, sqrt, 'x% of y')."
    let displayName = "Calculator"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [ToolParameter("expression", .string, "The math expression, e.g. '15% of 80' or '(3+4)*12'.", required: true)]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let expression = try arguments.requiredString("expression")
        do {
            let value = try Calculator.evaluate(expression)
            return ToolResult(summary: "\(expression) = \(Calculator.format(value))",
                              historyTitle: "Calculation")
        } catch Calculator.CalcError.divisionByZero {
            return .failure("You can't divide by zero.")
        } catch {
            return .failure("I couldn't calculate that.")
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
