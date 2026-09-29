import Foundation

/// Parses due dates from either ISO-8601 (what the model is asked to produce) or natural
/// language ("tomorrow at 5", "next Friday 9am") using Foundation's on-device `NSDataDetector`.
public enum NaturalDateParser {
    public struct Match: Sendable {
        public var date: Date
        public var hasTime: Bool
        public var range: Range<String.Index>
    }

    public struct ParsedDate: Sendable, Equatable {
        public var date: Date
        public var hasTime: Bool
    }

    public static func parse(_ string: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedDate? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let iso = parseISO(trimmed, calendar: calendar) { return iso }
        let lowered = trimmed.lowercased()
        if lowered == "today" || lowered == "tomorrow" {
            let base = calendar.startOfDay(for: now)
            let date = lowered == "today" ? base : calendar.date(byAdding: .day, value: 1, to: base)!
            return ParsedDate(date: date, hasTime: false)
        }
        if let match = firstDate(in: trimmed, now: now, calendar: calendar) {
            return ParsedDate(date: match.date, hasTime: match.hasTime)
        }
        return nil
    }

    public static func parseISO(_ string: String, calendar: Calendar = .current) -> ParsedDate? {
        let withZone = ISO8601DateFormatter()
        withZone.formatOptions = [.withInternetDateTime]
        if let date = withZone.date(from: string) { return ParsedDate(date: date, hasTime: true) }
        withZone.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withZone.date(from: string) { return ParsedDate(date: date, hasTime: true) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return ParsedDate(date: date, hasTime: true) }
        }
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: string) { return ParsedDate(date: date, hasTime: false) }
        return nil
    }

    /// Finds the first date expression inside free text.
    public static func firstDate(in text: String, now: Date = Date(), calendar: Calendar = .current) -> Match? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let result = detector.firstMatch(in: text, options: [], range: nsRange),
              var date = result.date,
              let range = Range(result.range, in: text) else { return nil }

        let phrase = text[range].lowercased()
        let hasTime = phrase.range(of: timePattern, options: .regularExpression) != nil

        if hasTime {
            // "at 5" without am/pm: people mean the afternoon for 1–6 o'clock.
            let explicitMeridiem = phrase.range(of: #"(\d\s*(am|pm|a\.m\.|p\.m\.))|morning|noon|midnight"#,
                                                options: .regularExpression) != nil
            let hour = calendar.component(.hour, from: date)
            if !explicitMeridiem, (1...6).contains(hour) {
                date = calendar.date(byAdding: .hour, value: 12, to: date) ?? date
            }
            // A time earlier than now with no day means the next occurrence.
            let mentionsDay = phrase.range(of: dayPattern, options: .regularExpression) != nil
            if !mentionsDay, date < now {
                date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            }
        } else {
            date = calendar.startOfDay(for: date)
        }
        return Match(date: date, hasTime: hasTime, range: range)
    }

    static let timePattern = #"(\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.))|(\d{1,2}:\d{2})|\b(at|by|around) \d{1,2}\b|noon|midnight|morning|afternoon|evening|tonight|o'clock"#
    static let dayPattern = #"today|tonight|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next|\d{1,2}(st|nd|rd|th)|january|february|march|april|may|june|july|august|september|october|november|december|/"#

    /// ISO string handed from the router to tools (local time with offset).
    public static func isoString(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}

/// Turns free text into a safe project folder name. The result is used as a path
/// component, so it is restricted to `[a-z0-9-]`.
public enum ProjectNameSanitizer {
    public static func sanitize(_ name: String, fallback: String = "ivy-project") -> String {
        let lowered = name.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        var slug = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > 40 {
            slug = String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return slug.isEmpty ? fallback : slug
    }

    static let stopWords: Set<String> = ["a", "an", "the", "my", "me", "new", "simple", "some", "for", "please",
                                         "with", "that", "which", "using", "in", "on", "to", "of", "and", "small", "little"]
    static let verbs: Set<String> = ["build", "building", "create", "creating", "make", "making", "write", "writing",
                                     "develop", "developing", "code", "coding", "scaffold", "scaffolding",
                                     "implement", "implementing", "fix", "fixing", "work", "working", "start", "starting"]

    /// "building a personal website with a blog" → "personal-website"
    public static func projectName(fromTask task: String) -> String {
        var words = task.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        while let first = words.first, verbs.contains(first) || stopWords.contains(first) || first == "on" {
            words.removeFirst()
        }
        var picked: [String] = []
        for word in words {
            if ["with", "that", "which", "using", "for", "where", "including"].contains(word) { break }
            if stopWords.contains(word) { continue }
            picked.append(word)
            if picked.count == 3 { break }
        }
        return sanitize(picked.joined(separator: "-"))
    }
}
