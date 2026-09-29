import Foundation

/// Fast paths for timers, math, system controls, weather, calendar and the browser.
extension CommandRouter {
    static let browsers: [String: String] = [
        "chrome": "Google Chrome", "google chrome": "Google Chrome", "safari": "Safari", "firefox": "Firefox",
        "arc": "Arc", "brave": "Brave Browser", "edge": "Microsoft Edge", "microsoft edge": "Microsoft Edge",
        "opera": "Opera", "the browser": "", "my browser": "", "browser": "",
    ]

    // MARK: Timers & alarms

    func routeTimers(_ text: String, original: String) -> ToolCall? {
        if matches(text, #"^(cancel|stop|delete|remove|clear|dismiss)( the| my| all( my)?| all the)? (timers?|alarms?)$"#) {
            return ToolCall(name: ToolName.timerCancel)
        }
        if matches(text, #"^how (much|long)( time)? (is )?(left|remaining)"#)
            || matches(text, #"^(what are|show|list|show me)( my| the)? (timers|alarms)$"#)
            || matches(text, #"^(what('s| is)|check)( on)? (my|the) timer$"#) {
            return ToolCall(name: ToolName.timerList)
        }

        let isTimer = matches(text, #"\btimer\b"#)
        let isAlarm = matches(text, #"^((set|create|make|add)( me)?( up)?( an?)? alarm|wake me( up)?)\b"#)
        guard isTimer || isAlarm else { return nil }
        guard matches(text, #"^((set|start|create|make|add|put)( me)?( up)?( on)?( an?| another)? |wake me( up)? )|timer (for|of)|^\S+( \S+)? timer"#)
            || text.hasPrefix("timer") else { return nil }

        var arguments: [String: JSONValue] = [:]
        if let label = capture(text, #"\b(?:called|named|labeled|for the|for my)\s+([a-z][a-z ]{1,30})$"#),
           DurationParser.seconds(in: label) == nil {
            arguments["label"] = .string(label.trimmingCharacters(in: .whitespaces))
        }
        if !isAlarm, let seconds = DurationParser.seconds(in: text) {
            arguments["duration"] = .string(DurationParser.describe(seconds))
            return ToolCall(name: ToolName.timerSet, arguments: arguments)
        }
        // "timer for 12 a.m.", "alarm at 7", "wake me up at 6:30"
        if let match = NaturalDateParser.firstDate(in: original, now: now()), match.hasTime {
            arguments["at"] = .string(NaturalDateParser.isoString(match.date))
            return ToolCall(name: ToolName.timerSet, arguments: arguments)
        }
        return nil
    }

    // MARK: Math

    func routeCalculation(_ text: String) -> ToolCall? {
        guard let expression = capture(text, #"^(?:what(?:'s| is)|calculate|compute|how much is|solve)\s+(.+?)$"#) ?? (Calculator.looksLikeMath(text) ? text : nil),
              Calculator.looksLikeMath(expression), (try? Calculator.evaluate(expression)) != nil else { return nil }
        return ToolCall(name: ToolName.calculate, arguments: ["expression": .string(expression)])
    }

    // MARK: System

    func routeSystem(_ text: String) -> ToolCall? {
        if matches(text, #"^(turn on|enable|switch to|activate|use) (the )?dark mode$"#) || text == "dark mode on" {
            return ToolCall(name: ToolName.darkMode, arguments: ["mode": "dark"])
        }
        if matches(text, #"^(turn off|disable) (the )?dark mode$"#) || matches(text, #"^(switch to|use|turn on|enable) (the )?light mode$"#) {
            return ToolCall(name: ToolName.darkMode, arguments: ["mode": "light"])
        }
        if matches(text, #"^toggle (the )?(dark|light) mode$"#) {
            return ToolCall(name: ToolName.darkMode, arguments: ["mode": "toggle"])
        }
        if matches(text, #"^(mute|silence)( the)?( mac| sound| audio| computer| volume)?$"#) {
            return ToolCall(name: ToolName.systemVolume, arguments: ["action": "mute"])
        }
        if matches(text, #"^(unmute)( the)?( mac| sound| audio| computer| volume)?$"#) {
            return ToolCall(name: ToolName.systemVolume, arguments: ["action": "unmute"])
        }
        if let level = capture(text, #"^set( the)? (system|mac|computer) volume to (\d{1,3})( percent|%)?$"#, group: 3), let value = Int(level) {
            return ToolCall(name: ToolName.systemVolume, arguments: ["action": "set", "level": .number(Double(value))])
        }
        if matches(text, #"^(turn|set)( the)? (system|mac|computer) volume (up|down)$"#) {
            return ToolCall(name: ToolName.systemVolume, arguments: ["action": .string(text.hasSuffix("up") ? "up" : "down")])
        }
        if matches(text, #"^(how much|what('s| is)( my)?) battery"#) || matches(text, #"battery (level|left|percentage|status)$"#) {
            return ToolCall(name: ToolName.systemInfo, arguments: ["kind": "battery"])
        }
        if matches(text, #"(disk|storage) (space|left|free)|how much (free )?(disk|storage)"#) {
            return ToolCall(name: ToolName.systemInfo, arguments: ["kind": "disk"])
        }
        if matches(text, #"^what('s| is) the time( now| right now)?$"#) || matches(text, #"^what time is it( now| right now)?$"#) {
            return ToolCall(name: ToolName.systemInfo, arguments: ["kind": "time"])
        }
        if matches(text, #"^what('s| is) (the date|today's date)( today)?$"#) || matches(text, #"^what day is (it|today)$"#) {
            return ToolCall(name: ToolName.systemInfo, arguments: ["kind": "date"])
        }
        return nil
    }

    // MARK: Weather & calendar

    func routeWeather(_ text: String) -> ToolCall? {
        guard matches(text, #"\b(weather|forecast|temperature outside|rain|snow)\b"#),
              matches(text, #"^(what('s| is| will)|how('s| is)|will it|is it going to|show|tell me|weather|forecast|do i need)"#) else { return nil }
        var arguments: [String: JSONValue] = [:]
        if let place = capture(text, #"\b(?:in|for|at) ([a-z][a-z .'-]+?)(?: today| tomorrow| this week| right now| now)?$"#),
           !["today", "tomorrow", "the morning", "the evening"].contains(place) {
            arguments["location"] = .string(place.capitalized)
        }
        if text.contains("tomorrow") { arguments["day"] = "tomorrow" }
        return ToolCall(name: ToolName.weather, arguments: arguments)
    }

    func routeCalendar(_ text: String) -> ToolCall? {
        guard matches(text, #"\b(calendar|schedule|meetings?|events?|appointments?|agenda)\b"#),
              matches(text, #"^(what('s| is| are)|do i have|show|list|read|any|how many)"#) else { return nil }
        let scope = text.contains("tomorrow") ? "tomorrow" : text.contains("week") ? "week" : "today"
        return ToolCall(name: ToolName.calendarEvents, arguments: ["scope": .string(scope)])
    }

    // MARK: Browser & web

    /// "open chrome and search for the eiffel tower", "google best pizza", "search youtube in safari"
    func routeBrowserSearch(_ text: String) -> ToolCall? {
        let browserNames = Self.browsers.keys.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let verbs = #"(?:search(?: google| the web| online)?(?: for)?|google|look up|find(?: me)?|get(?: me)?|show me|look for)"#

        if let groups = captureGroups(text, #"^(?:open|launch|start|use|go to|in) (\#(browserNames))(?:,)?(?: and)? \#(verbs) (.+)$"#) {
            return browserCall(query: groups[1], browser: groups[0])
        }
        if let groups = captureGroups(text, #"^\#(verbs) (.+?) (?:in|on|with|using) (\#(browserNames))$"#) {
            return browserCall(query: groups[0], browser: groups[1])
        }
        if let query = capture(text, #"^(?:google|search google for|search on google for|google search) (.+)$"#) {
            return browserCall(query: query, browser: nil)
        }
        return nil
    }

    /// "look up …" / "search the web for …" → answer in the notch with sources.
    func routeWebLookup(_ text: String) -> ToolCall? {
        guard let query = capture(text, #"^(?:search the (?:web|internet) for|look up|search online for|find out|check online) (.+)$"#) else {
            return nil
        }
        return ToolCall(name: ToolName.webSearch, arguments: ["query": .string(query)])
    }

    private func browserCall(query rawQuery: String, browser rawBrowser: String?) -> ToolCall? {
        var query = rawQuery.trimmingCharacters(in: .whitespaces)
        query = query.replacingOccurrences(of: #"^(for|me|an?|the|some)\s+"#, with: "", options: .regularExpression)
        guard !query.isEmpty else { return nil }
        var arguments: [String: JSONValue] = ["query": .string(query)]
        if let rawBrowser, let app = Self.browsers[rawBrowser], !app.isEmpty {
            arguments["browser"] = .string(app)
        }
        return ToolCall(name: ToolName.browserSearch, arguments: arguments)
    }

    func captureGroups(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
