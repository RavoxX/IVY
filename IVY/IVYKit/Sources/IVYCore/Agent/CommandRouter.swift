import Foundation

/// Deterministic fast path for unambiguous commands.
///
/// A 4B model is good at picking tools, but "pause", "next song" or "open Safari" do not
/// need a model at all. Routing them directly makes IVY respond instantly, keeps the GPU
/// idle on a fanless MacBook Air, and still works while the model is loading. Anything
/// the router is not confident about returns `nil` and goes to the local LLM.
public struct CommandRouter: Sendable {
    /// Returns the canonical name of an installed application matching the spoken name, if any.
    public typealias AppResolver = @Sendable (String) -> String?

    private let resolveApp: AppResolver
    let now: @Sendable () -> Date

    public init(resolveApp: @escaping AppResolver, now: @escaping @Sendable () -> Date = { Date() }) {
        self.resolveApp = resolveApp
        self.now = now
    }

    public static let knownFolders: [String: String] = [
        "downloads": "~/Downloads",
        "documents": "~/Documents",
        "desktop": "~/Desktop",
        "pictures": "~/Pictures",
        "movies": "~/Movies",
        "home": "~",
        "applications": "/Applications",
    ]
    /// Folder names that are also app names ("Home" app) and need an explicit "folder".
    static let ambiguousFolders: Set<String> = ["home", "applications"]

    public func route(_ input: String) -> ToolCall? {
        let text = Self.normalize(input)
        guard !text.isEmpty else { return nil }
        if ["undo", "undo my last action", "undo last action", "rückgängig", "letzte aktion rückgängig"].contains(text) { return ToolCall(name: ToolName.undoLastAction) }

        if let call = routeSettings(text, original: input) { return call }
        // "Remind me … and add it to my calendar too" needs several tools: the model plans those.
        // Only the deliberate two-step phrasings below stay on the fast path.
        if ChainDetector.isCompound(text) {
            return routeBrowserSearch(text) ?? routeCodingSession(text, original: input)
        }
        if let call = routeTimers(text, original: input) { return call }
        if let call = routeCalculation(text) { return call }
        if let call = routeDictionary(text) { return call }
        if let call = routeClipboard(text) { return call }
        if let call = routeSystem(text) { return call }
        if let call = routeLowPower(text) { return call }
        if let call = routeEnergy(text) { return call }
        if let call = routeFocus(text) { return call }
        if let call = routeMail(text) { return call }
        if let call = routeFiles(text) { return call }
        if let call = routeShortcut(text) { return call }
        if let call = routeWeather(text) { return call }
        if let call = routeCalendar(text) { return call }
        if let call = routeBrowserSearch(text) { return call }
        if let call = routeWebLookup(text) { return call }
        if let call = routeMusic(text) { return call }
        if let call = routeReminders(text, original: input) { return call }
        if let call = routeCodingSession(text, original: input) { return call }
        if let call = routeClose(text) { return call }
        if let call = routeOpen(text, original: input) { return call }
        return nil
    }

    // MARK: - Normalization

    static let leadingFillers = [
        "hey ivy", "hi ivy", "ok ivy", "okay ivy", "ivy", "please", "can you please", "could you please",
        "can you", "could you", "would you", "will you", "i want you to", "i'd like you to", "go ahead and",
    ]
    static let trailingFillers = ["please", "for me", "now", "thanks", "thank you"]

    public static func normalize(_ input: String) -> String {
        var text = input.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;: "))
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        var changed = true
        while changed {
            changed = false
            for filler in leadingFillers where text == filler || text.hasPrefix(filler + " ") || text.hasPrefix(filler + ", ") {
                text = String(text.dropFirst(filler.count)).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                changed = true
            }
            for filler in trailingFillers where text.hasSuffix(" " + filler) || text.hasSuffix(", " + filler) {
                text = String(text.dropLast(filler.count)).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                changed = true
            }
        }
        return text
    }

    // MARK: - Settings

    private func routeSettings(_ text: String, original: String) -> ToolCall? {
        // Normalization strips a leading "IVY", so check the raw input for the name.
        let mentionsIVY = original.lowercased().range(of: #"\bivy\b"#, options: .regularExpression) != nil
        let pattern = #"^((open|show|launch|go to|bring up) )?(the |your |my )?(ivy'?s? )?(settings|preferences|options)( window)?$"#
        if mentionsIVY, matches(text, pattern) || text == "settings for ivy" {
            return ToolCall(name: ToolName.openSettings)
        }
        return nil
    }

    // MARK: - Music

    private func routeMusic(_ text: String) -> ToolCall? {
        let musicNoun = #"( the| my| some)?( music| song| track| spotify| playback| audio)?"#

        if matches(text, #"^(pause|stop)"# + musicNoun + "( playing)?$") || text == "stop playing" {
            return ToolCall(name: ToolName.musicControl, arguments: ["action": "pause"])
        }
        if matches(text, #"^(resume|continue|unpause)"# + musicNoun + "( playing)?$") {
            return ToolCall(name: ToolName.musicControl, arguments: ["action": "resume"])
        }
        if matches(text, #"^(play|start)( playing)?( some| the| my)? (music|spotify|songs)$"#) || text == "play" {
            return ToolCall(name: ToolName.musicPlay)
        }
        if matches(text, #"^((play|go to|skip to)( the)? )?next( song| track| one)?$"#)
            || matches(text, #"^skip( this| the)?( song| track| one)?$"#) {
            return ToolCall(name: ToolName.musicControl, arguments: ["action": "next"])
        }
        if matches(text, #"^((play|go to|go back to)( the)? )?(previous|last|prev)( song| track| one)$"#)
            || matches(text, #"^go back( a| one)?( song| track)?$"#) || text == "previous" {
            return ToolCall(name: ToolName.musicControl, arguments: ["action": "previous"])
        }
        if matches(text, #"^what('s| is)( currently| now)? playing( right now)?$"#)
            || matches(text, #"^what('s| is) (this|the|that) (song|track)( called)?$"#)
            || matches(text, #"^what song is (this|playing)$"#)
            || text == "now playing" || text == "which song is this" {
            return ToolCall(name: ToolName.musicNowPlaying)
        }
        if let call = routeVolume(text) { return call }

        // "play billie jean", "play thriller by michael jackson on spotify"
        if let captured = capture(text, #"^play (.+)$"#) {
            let query = Self.cleanSongQuery(captured)
            let blocked = ["a game", "a video", "the video", "video", "a movie", "movie", "the game"]
            if !query.isEmpty, !blocked.contains(query), !query.hasPrefix("with ") {
                return ToolCall(name: ToolName.musicPlay, arguments: ["query": .string(query)])
            }
        }
        return nil
    }

    /// "the song timber from spotify" → "timber"
    static func cleanSongQuery(_ raw: String) -> String {
        var query = raw.trimmingCharacters(in: .whitespaces)
        query = query.replacingOccurrences(of: #"\s+(on|from|in|with|using|via)\s+(spotify|apple music|music)$"#, with: "",
                                           options: .regularExpression)
        query = query.replacingOccurrences(of: #"^(me |us )?(the |a |some )?(song|track|music|tune)( called| named)?\s+"#, with: "",
                                           options: .regularExpression)
        query = query.replacingOccurrences(of: #"\s+(song|track)$"#, with: "", options: .regularExpression)
        return query.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”"))
    }

    private func routeVolume(_ text: String) -> ToolCall? {
        if let level = capture(text, #"^(set|change|turn)( the)?( music| spotify)? volume to (\d{1,3})( percent|%)?$"#, group: 4),
           let value = Int(level) {
            return ToolCall(name: ToolName.musicVolume, arguments: ["level": .number(Double(min(100, value)))])
        }
        if matches(text, #"^(turn|crank|bump)( the)?( music| volume| sound| it| spotify)( volume)? up( a bit| a little)?$"#)
            || matches(text, #"^(volume|music) up$"#) || text == "louder" || text == "make it louder" {
            return ToolCall(name: ToolName.musicVolume, arguments: ["direction": "up"])
        }
        if matches(text, #"^(turn)( the)?( music| volume| sound| it| spotify)( volume)? down( a bit| a little)?$"#)
            || matches(text, #"^(volume|music) down$"#) || ["quieter", "softer", "make it quieter"].contains(text) {
            return ToolCall(name: ToolName.musicVolume, arguments: ["direction": "down"])
        }
        return nil
    }

    // MARK: - Reminders

    private func routeReminders(_ text: String, original: String) -> ToolCall? {
        let todo = #"(to-?do|todo|to do)( list)?"#
        if matches(text, #"^what('s| is| are)( on)? my "# + todo + #"( for)?( today| this morning| tonight)?$"#)
            || matches(text, #"^(show|list|read)( me)? my ("# + todo + #"|reminders|tasks|todos)( for)?( today)?$"#)
            || matches(text, #"^what (are|is) my (reminders|tasks|todos)( for)?( today)?$"#)
            || matches(text, #"^what do i (have|need) to do( today)?$"#)
            || matches(text, #"^(do i have )?any (reminders|tasks)( for)?( today)?$"#) {
            return ToolCall(name: ToolName.remindersList, arguments: ["scope": "today"])
        }
        if matches(text, #"^(what('s| is| are)|show|list)( me)?( my)? overdue( reminders| tasks)?$"#)
            || matches(text, #"^what('s| is) overdue$"#) {
            return ToolCall(name: ToolName.remindersList, arguments: ["scope": "overdue"])
        }
        if matches(text, #"^(what('s| is| are)|show|list)( me)?( my)? upcoming( reminders| tasks)?( this week)?$"#) {
            return ToolCall(name: ToolName.remindersList, arguments: ["scope": "upcoming"])
        }

        // "Remind me tomorrow at 5 to call Alex" / "Remind me to call Alex tomorrow at 5pm"
        if text.hasPrefix("remind me") || text.hasPrefix("add a reminder") || text.hasPrefix("create a reminder") {
            return parseReminderCreation(original)
        }
        return nil
    }

    func parseReminderCreation(_ original: String) -> ToolCall? {
        var working = original.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        // Strip filler prefixes while preserving the original casing of the title.
        let prefixPattern = #"^(?i)(hey ivy,?\s*|ivy,?\s*|please\s*|can you\s*|could you\s*)*(remind me|add a reminder|create a reminder)(\s+(to|that|about|for)\b)?\s*"#
        working = working.replacingOccurrences(of: prefixPattern, with: "", options: .regularExpression)

        var arguments: [String: JSONValue] = [:]
        if let match = NaturalDateParser.firstDate(in: working, now: now()) {
            arguments["due"] = .string(NaturalDateParser.isoString(match.date))
            working.removeSubrange(match.range)
        }
        var title = working
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacingOccurrences(of: #"^(?i)(to|that|about|for)\s+"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"(?i)\s+(on|at|by)$"#, with: "", options: .regularExpression)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        guard !title.isEmpty else { return nil }
        arguments["title"] = .string(title.prefix(1).uppercased() + title.dropFirst())
        return ToolCall(name: ToolName.remindersCreate, arguments: arguments)
    }

    // MARK: - Coding sessions

    private func routeCodingSession(_ text: String, original: String) -> ToolCall? {
        let agents: [(String, String)] = [("claude code", "claude"), ("claude", "claude"), ("codex", "codex")]
        guard let agent = agents.first(where: { text.contains($0.0) }),
              text.contains("session") || text.contains("open") || text.contains("start") || text.contains("use")
                || text.contains("launch") || text.contains("ask")
        else { return nil }
        // Only "claude code"/"codex" mentions; plain "claude" must at least mention coding.
        if agent.0 == "claude", !text.contains("code") { return nil }

        let verbs = #"(build|building|create|creating|make|making|write|writing|develop|developing|code|coding|scaffold|scaffolding|implement|implementing|fix|fixing|work on|working on)"#
        // Remove the agent's name first so "claude code" doesn't match the verb "code".
        let withoutAgent = text.replacingOccurrences(of: agent.0, with: "agent")
        guard let range = withoutAgent.range(of: #"\b"# + verbs + #"\b.*$"#, options: .regularExpression) else {
            // "Open Claude Code" / "start a Claude Code session": just open an interactive session.
            guard agent.0 != "claude" || text.contains("claude code") else { return nil }
            return ToolCall(name: ToolName.startCodingSession, arguments: ["agent": .string(agent.1)])
        }
        let taskPhrase = String(withoutAgent[range])
        let task = Self.imperative(taskPhrase)
        let project = ProjectNameSanitizer.projectName(fromTask: taskPhrase)
        return ToolCall(name: ToolName.startCodingSession, arguments: [
            "project_name": .string(project),
            "task": .string(task),
            "agent": .string(agent.1),
        ])
    }

    /// "building a personal website" → "Build a personal website".
    static func imperative(_ phrase: String) -> String {
        var words = phrase.split(separator: " ").map(String.init)
        guard let first = words.first else { return phrase }
        let map = ["building": "build", "creating": "create", "making": "make", "writing": "write",
                   "developing": "develop", "coding": "code", "scaffolding": "scaffold",
                   "implementing": "implement", "fixing": "fix", "working": "work"]
        words[0] = map[first] ?? first
        let sentence = words.joined(separator: " ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    // MARK: - Open apps / URLs / folders

    private func routeClose(_ text: String) -> ToolCall? {
        guard let target = capture(text, #"^(close|quit|force quit|force-quit|kill|terminate|exit|schließe|schliesse|schließ|schliess|beende|schließen|schliessen)( the| die| das)? (.+)$"#, group: 3),
              !target.contains(" and "), !target.contains(" then "), !target.contains(" und "),
              !matches(target, #"\b(tabs?|windows?|fenster|process|processes|prozess|prozesse)\b"#) else { return nil }
        let appName = target.replacingOccurrences(of: #" (app|application|anwendung)$"#, with: "", options: .regularExpression)
        guard resolveApp(appName) != nil else { return nil }
        // Keep the user's target: installed-app fuzzy matching must not select a
        // different running app. The closing tool requires a unique running match.
        return ToolCall(name: ToolName.closeApp, arguments: ["name": .string(appName)])
    }

    private func routeOpen(_ text: String, original: String) -> ToolCall? {
        guard let target = capture(text, #"^(open|launch|start|show|go to|take me to)( up)? (.+)$"#, group: 3) else {
            return nil
        }
        var object = target
        for prefix in ["the ", "my ", "up "] where object.hasPrefix(prefix) {
            object = String(object.dropFirst(prefix.count))
        }
        // Compound requests ("open X and do Y") need the model.
        guard !object.contains(" and "), !object.contains(" then "), object.split(separator: " ").count <= 5 else {
            return nil
        }

        // URLs: "github.com", "https://apple.com/mac"
        if matches(object, #"^(https?://)?[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(/\S*)?$"#) {
            let url = object.hasPrefix("http") ? object : "https://\(object)"
            return ToolCall(name: ToolName.openURL, arguments: ["url": .string(url)])
        }

        // Well-known folders: "downloads", "my downloads folder"
        let folderKey = object.replacingOccurrences(of: #" (folder|directory)$"#, with: "", options: .regularExpression)
        let isExplicitFolder = folderKey != object
        if let path = Self.knownFolders[folderKey], isExplicitFolder || !Self.ambiguousFolders.contains(folderKey) {
            return ToolCall(name: ToolName.openFile, arguments: ["path": .string(path)])
        }

        // Applications: only when an installed app actually matches.
        let appName = object.replacingOccurrences(of: #" (app|application)$"#, with: "", options: .regularExpression)
        if let resolved = resolveApp(appName) {
            return ToolCall(name: ToolName.openApp, arguments: ["name": .string(resolved)])
        }
        return nil
    }

    // MARK: - Regex helpers

    func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    func capture(_ text: String, _ pattern: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > group,
              let captured = Range(match.range(at: group), in: text) else { return nil }
        return String(text[captured])
    }
}
