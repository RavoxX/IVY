import Foundation

/// Matches spoken requests to the user's own Shortcuts. HomeKit isn't available to macOS
/// apps, so Home scenes, lights, thermostats and Focus switching run through Shortcuts
/// the user created. IVY only runs shortcuts that exist; it never builds commands from text.
public enum ShortcutMatcher {
    /// Words that make a shortcut high risk (confirmation required).
    static let sensitiveWords: Set<String> = [
        "lock", "unlock", "door", "doors", "garage", "gate", "alarm", "security", "arm", "disarm",
        "delete", "remove", "erase", "send", "pay", "buy", "purchase", "order", "email", "message", "post", "tweet",
        "tür", "tur", "schloss", "abschließen", "abschliessen", "aufschließen", "aufschliessen", "tor", "alarmanlage",
        "löschen", "loschen", "senden", "schicken", "bezahlen", "kaufen", "bestellen",
    ]

    public static func isSensitive(_ name: String) -> Bool {
        !Set(tokens(name)).isDisjoint(with: sensitiveWords)
    }

    /// Best match for `query`, or nil when nothing is close enough to be safe to run.
    public static func best(for query: String, in shortcuts: [ShortcutInfo]) -> ShortcutInfo? {
        let wanted = fold(query)
        guard !wanted.isEmpty else { return nil }
        if let exact = shortcuts.first(where: { fold($0.name) == wanted }) { return exact }
        let queryTokens = Set(tokens(query))
        guard !queryTokens.isEmpty else { return nil }
        var best: (ShortcutInfo, Double)?
        for shortcut in shortcuts {
            let nameTokens = Set(tokens(shortcut.name))
            guard !nameTokens.isEmpty else { continue }
            let shared = Double(queryTokens.intersection(nameTokens).count)
            // Share of the shortcut's name that the request covers, weighted with the request's share.
            let score = shared / Double(nameTokens.count) * 0.6 + shared / Double(queryTokens.count) * 0.4
            if score > (best?.1 ?? 0) || (score == best?.1 && shortcut.name.count < best!.0.name.count) {
                best = (shortcut, score)
            }
        }
        guard let best, best.1 >= 0.5 else { return nil }
        return best.0
    }

    /// Two or more shortcuts fit about equally well: ask which one instead of guessing.
    public static func ambiguous(for query: String, in shortcuts: [ShortcutInfo]) -> [ShortcutInfo]? {
        let wanted = fold(query)
        guard !wanted.isEmpty, !shortcuts.contains(where: { fold($0.name) == wanted }) else { return nil }
        let queryTokens = Set(tokens(query))
        guard !queryTokens.isEmpty else { return nil }
        let scored = shortcuts.map { shortcut -> (ShortcutInfo, Double) in
            let nameTokens = Set(tokens(shortcut.name))
            guard !nameTokens.isEmpty else { return (shortcut, 0) }
            let shared = Double(queryTokens.intersection(nameTokens).count)
            return (shortcut, shared / Double(nameTokens.count) * 0.6 + shared / Double(queryTokens.count) * 0.4)
        }.filter { $0.1 >= 0.5 }.sorted { $0.1 > $1.1 }
        guard scored.count > 1, scored[0].1 - scored[1].1 < 0.1 else { return nil }
        return scored.prefix(3).map(\.0)
    }

    /// Shortcut that switches a Focus on ("Work Focus", "Fokus Arbeit") or off ("Focus Off").
    public static func focusShortcut(named focus: String?, on: Bool, in shortcuts: [ShortcutInfo]) -> ShortcutInfo? {
        let expected = ShortcutBuilder.focusShortcutName(focus: focus, on: on)
        if let exact = shortcuts.first(where: { $0.name.caseInsensitiveCompare(expected) == .orderedSame }) { return exact }
        let focusWords: Set<String> = ["focus", "fokus", "dnd", "disturb", "stören", "storen"]
        let offWords: Set<String> = ["off", "aus", "stop", "end", "beenden", "disable", "deaktivieren"]
        let candidates = shortcuts.filter { !Set(tokens($0.name)).isDisjoint(with: focusWords) }
        if !on {
            let offShortcuts = candidates.filter { !Set(tokens($0.name)).isDisjoint(with: offWords) }
            let mode = Set(tokens(focus ?? "").map(FocusParser.stem)).subtracting(focusWords)
            // "Sleep Focus Off" for Sleep, else a generic "Focus Off" (no other mode's name in it).
            return offShortcuts.first { !mode.isEmpty && !Set(tokens($0.name).map(FocusParser.stem)).isDisjoint(with: mode) }
                ?? offShortcuts.first { Set(tokens($0.name)).subtracting(focusWords).subtracting(offWords).isEmpty }
        }
        let wanted = Set(tokens(focus ?? "").map(FocusParser.stem)).subtracting(focusWords)
        return candidates
            .filter { Set(tokens($0.name)).isDisjoint(with: offWords) }
            .first { wanted.isEmpty || !Set(tokens($0.name).map(FocusParser.stem)).isDisjoint(with: wanted) }
    }

    static func fold(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }

    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
            .filter { !["the", "a", "my", "to", "die", "der", "das", "den"].contains($0) }
    }
}

/// Reads the active Focus from the DoNotDisturb database JSON files (needs Full Disk Access).
public enum FocusParser {
    public static func activeModeIdentifier(assertions data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { return nil }
        for entry in entries {
            guard let records = entry["storeAssertionRecords"] as? [[String: Any]] else { continue }
            for record in records {
                if let details = record["assertionDetails"] as? [String: Any],
                   let identifier = details["assertionDetailsModeIdentifier"] as? String {
                    return identifier
                }
            }
        }
        return nil
    }

    public static func modeNames(configurations data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { return [:] }
        var names: [String: String] = [:]
        for entry in entries {
            guard let configurations = entry["modeConfigurations"] as? [String: Any] else { continue }
            for (identifier, value) in configurations {
                if let mode = (value as? [String: Any])?["mode"] as? [String: Any], let name = mode["name"] as? String {
                    names[identifier] = name
                }
            }
        }
        return names
    }

    /// Human name for a mode identifier, falling back to the identifier's last component.
    public static func displayName(for identifier: String, names: [String: String]) -> String {
        if let name = names[identifier] { return name }
        switch identifier {
        case "com.apple.donotdisturb.mode.default": return "Do Not Disturb"
        case "com.apple.sleep.sleep-mode": return "Sleep"
        case "com.apple.focus.work": return "Work"
        case "com.apple.focus.personal-time": return "Personal"
        case "com.apple.focus.reduce-interruptions": return "Reduce Interruptions"
        default:
            let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
            return last.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    /// Apple's standard Focus modes, used when the user's own list can't be read.
    public static let standardModes = ["Do Not Disturb", "Sleep", "Work", "Personal", "Driving", "Fitness", "Gaming",
                                       "Mindfulness", "Reading", "Reduce Interruptions"]

    static let aliases: [String: String] = [
        "dnd": "Do Not Disturb", "disturb": "Do Not Disturb", "nicht stören": "Do Not Disturb",
        "bed": "Sleep", "bedtime": "Sleep", "night": "Sleep", "schlafen": "Sleep", "schlaf": "Sleep",
        "arbeit": "Work", "arbeiten": "Work", "office": "Work", "privat": "Personal", "fahren": "Driving",
    ]

    /// "sleeping" → "sleep", "working" → "work".
    static func stem(_ word: String) -> String {
        var word = word.lowercased()
        if word.count > 5, word.hasSuffix("ing") { word.removeLast(3) }
        return word
    }

    /// Maps what the user said ("sleeping", "dnd", "work mode") to one of their Focus names.
    public static func canonicalName(_ spoken: String, known: [String]) -> String {
        let cleaned = spoken.lowercased()
            .replacingOccurrences(of: #"\b(focus|fokus|mode|modus)\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return spoken }
        if let alias = aliases[cleaned] { return known.first { $0.caseInsensitiveCompare(alias) == .orderedSame } ?? alias }
        let spokenStems = cleaned.split(separator: " ").map { stem(String($0)) }
        for name in known {
            let nameStems = name.lowercased().split(separator: " ").map { stem(String($0)) }
            if nameStems == spokenStems { return name }
        }
        for name in known {
            let nameStems = name.lowercased().split(separator: " ").map { stem(String($0)) }
            if let first = spokenStems.first, first.count >= 3,
               nameStems.contains(where: { $0.hasPrefix(first) || first.hasPrefix($0) }) { return name }
        }
        return cleaned.capitalized
    }

    /// Resolves what the user said to one of their Focus modes: the name macOS shows (the
    /// Set Focus action finds modes *by this name*, so it must be localized, e.g. "Nicht stören")
    /// and its system identifier.
    ///
    /// - Parameters:
    ///   - configured: identifier → name from the Focus database (needs Full Disk Access; covers
    ///     custom modes). Empty when unavailable.
    ///   - localized: standard English name → the system's localized name ("Do Not Disturb" →
    ///     "Nicht stören"), from macOS's own strings.
    public static func resolve(_ spoken: String, configured: [String: String],
                               localized: [String: String] = [:]) -> (name: String, identifier: String)? {
        let standard = ShortcutBuilder.standardFocusIdentifiers
        if !configured.isEmpty {
            let name = canonicalName(spoken, known: Array(configured.values))
            if let match = configured.first(where: { $0.value.caseInsensitiveCompare(name) == .orderedSame }) {
                return (match.value, match.key)
            }
        }
        // A localized name ("Arbeiten", "Zeit für mich") or an English one ("working", "dnd").
        var english: String?
        if !localized.isEmpty {
            let name = canonicalName(spoken, known: Array(localized.values))
            english = localized.first { $0.value.caseInsensitiveCompare(name) == .orderedSame }?.key
        }
        let resolvedEnglish = english ?? canonicalName(spoken, known: Array(standard.keys))
        guard let identifier = standard[resolvedEnglish] else { return nil }
        if !configured.isEmpty { return configured[identifier].map { ($0, identifier) } }
        return (localized[resolvedEnglish] ?? resolvedEnglish, identifier)
    }

    /// Focus modes where IVY should stay silent (no sounds, no spoken answers).
    public static func isQuiet(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["sleep", "do not disturb", "schlafen", "nicht stören", "driving", "fahren"].contains { lower.contains($0) }
    }

    /// Context for the model so replies fit the situation.
    public static func replyGuidance(for name: String) -> String {
        let lower = name.lowercased()
        if isQuiet(name) { return "Focus: \(name). Keep answers as short as possible." }
        if lower.contains("work") || lower.contains("arbeit") { return "Focus: \(name). Be brief and professional." }
        if lower.contains("personal") || lower.contains("privat") { return "Focus: \(name). A relaxed tone is fine." }
        return "Focus: \(name)."
    }
}

/// Detects one sentence that asks for several actions ("remind me … and add it to my calendar").
public enum ChainDetector {
    static let verbs = "remind|set|add|create|make|schedule|put|play|pause|stop|open|launch|start|turn|switch|text|send|email|show|tell|check|search|find|look|mute|unmute|copy|summari[sz]e|book|call|save|run|translate|convert|cancel|delete"

    public static func isCompound(_ normalized: String) -> Bool {
        let text = normalized
        let patterns = [
            #"(,|\band)\s+(then|also|afterwards|after that)\b"#,
            #"\bthen (\#(verbs))\b"#,
            #"(,\s*|\s)and (please |also )?(\#(verbs))\b"#,
            #";\s*\w"#,
        ]
        if patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) { return true }
        // "… and put it in my calendar too"
        return text.range(of: #"\b(too|as well)$"#, options: .regularExpression) != nil && text.contains(" and ")
    }
}
