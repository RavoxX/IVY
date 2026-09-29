import Foundation

public enum DictionaryMode: String, CaseIterable, Sendable {
    case define, synonyms, antonyms
}

/// Parsing and prompts for dictionary lookups. Definitions come from the offline macOS
/// dictionary; synonym/antonym lists come from the local model.
public enum WordLookup {
    /// "define serendipity", "what does ubiquitous mean", "synonyms for happy", "opposite of cold".
    public static func parse(_ normalized: String) -> (word: String, mode: DictionaryMode)? {
        let text = normalized
        let rules: [(String, DictionaryMode)] = [
            (#"^(?:give me |what are |what's |what is |list )?(?:some |a few )?(?:synonyms?|other words|another word|a different word|a better word)(?: for| of| to)? (.+)$"#, .synonyms),
            (#"^(?:what's |what is )?(?:a )?(?:thesaurus|synonym)(?: for| of) (.+)$"#, .synonyms),
            (#"^(?:give me |what are |what's |what is |list )?(?:some |an? )?(?:antonyms?|opposites?)(?: for| of| to)? (.+)$"#, .antonyms),
            (#"^(?:what's |what is )?the opposite of (.+)$"#, .antonyms),
            (#"^(?:define|definition of|define the word|look up the word|dictionary) (.+)$"#, .define),
            (#"^what(?:'s| is| does) (?:the )?(?:meaning|definition) of (.+)$"#, .define),
            (#"^what does (?:the word )?(.+?) mean$"#, .define),
            (#"^meaning of (.+)$"#, .define),
        ]
        for (pattern, mode) in rules {
            if let captured = text.firstMatch(pattern)?[1], let word = cleanWord(captured) {
                return (word, mode)
            }
        }
        return nil
    }

    /// Accepts 1–3 words of letters, hyphens and apostrophes ("well-being", "ad hoc").
    public static func cleanWord(_ raw: String) -> String? {
        var word = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’.?!,"))
        word = word.replacingOccurrences(of: #"^(the word|the term|the phrase|word|term) "#, with: "", options: .regularExpression)
        word = word.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’"))
        guard !word.isEmpty, word.count <= 40, word.split(separator: " ").count <= 3,
              word.range(of: #"^[\p{L}][\p{L}\p{M}'’ -]*$"#, options: .regularExpression) != nil else { return nil }
        return word
    }

    public static func listPrompt(mode: DictionaryMode, word: String) -> String {
        let kind = mode == .antonyms ? "antonyms (words with the opposite meaning)" : "synonyms"
        return "List up to 8 common \(kind) of the word \"\(word)\", most useful first, in the same language as the word. Reply with a comma-separated list only."
    }

    public static let listSystemPrompt = "You are a precise thesaurus. Reply only with the requested comma-separated words, nothing else."
    public static let definitionSystemPrompt = "You are a precise dictionary. Reply with one short plain definition sentence, nothing else."

    /// "1. glad, 2. cheerful\n- joyful" → ["glad", "cheerful", "joyful"], without the word itself.
    public static func parseList(_ raw: String, excluding word: String) -> [String] {
        let body = raw.replacingOccurrences(of: #"(?i)^(synonyms|antonyms)[^:]*:"#, with: "", options: .regularExpression)
        let pieces = body.components(separatedBy: CharacterSet(charactersIn: ",;\n•·"))
        var seen: Set<String> = [word.lowercased()]
        var result: [String] = []
        for piece in pieces {
            let item = piece
                .replacingOccurrences(of: #"^\s*(\d+[.)]|[-*])\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " .\"'“”"))
            guard !item.isEmpty, item.count <= 30, item.split(separator: " ").count <= 3,
                  seen.insert(item.lowercased()).inserted else { continue }
            result.append(item)
            if result.count == 8 { break }
        }
        return result
    }

    /// macOS dictionary text is dense ("hap·py | ˈhapē | adjective (happier, happiest) 1 feeling or
    /// showing pleasure…"). Keep the first sense, trimmed to a readable length.
    public static func cleanDefinition(_ raw: String, maxLength: Int = 320) -> String {
        var text = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Stop before the second numbered sense.
        if let second = text.range(of: #" 2 "#) { text = String(text[..<second.lowerBound]) }
        // Stop before all-caps section headers in any dictionary language
        // ("ORIGIN", "PHRASES", "HERKUNFT", "TYPISCHE VERBINDUNGEN", …).
        if let header = text.range(of: #" \p{Lu}{4,}(?= |$)"#, options: .regularExpression) {
            text = String(text[..<header.lowerBound])
        }
        if text.count > maxLength {
            let cut = text.prefix(maxLength)
            if let lastPeriod = cut.lastIndex(of: ".") ?? cut.lastIndex(of: ";") {
                text = String(cut[...lastPeriod])
            } else {
                text = cut + "…"
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    public static func summary(for result: DefinitionResult, mode: DictionaryMode) -> String {
        switch mode {
        case .synonyms:
            return result.synonyms.isEmpty ? "I couldn't find synonyms for “\(result.word)”."
                : "Synonyms for \(result.word): \(result.synonyms.prefix(5).joined(separator: ", "))."
        case .antonyms:
            return result.antonyms.isEmpty ? "I couldn't find antonyms for “\(result.word)”."
                : "Opposites of \(result.word): \(result.antonyms.prefix(5).joined(separator: ", "))."
        case .define:
            guard let definition = result.definition else { return "I couldn't find “\(result.word)” in the dictionary." }
            let short = definition.count > 160 ? String(definition.prefix(157)) + "…" : definition
            return result.fromSystemDictionary ? short : "\(result.word.capitalizedFirstWord): \(short)"
        }
    }
}
