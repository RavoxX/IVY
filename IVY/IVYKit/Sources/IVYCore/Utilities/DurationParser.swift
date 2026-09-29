import Foundation

/// Parses spoken durations: "5 minutes", "an hour and a half", "1h 30m", "ninety seconds".
public enum DurationParser {
    static let numberWords: [String: Double] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "twenty five": 25, "thirty": 30,
        "forty": 40, "forty five": 45, "fifty": 50, "sixty": 60, "ninety": 90, "a couple of": 2, "a few": 3,
    ]

    static let unitPattern = #"(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b"#

    /// Total seconds described by the text, or nil if no duration is present.
    public static func seconds(in text: String) -> TimeInterval? {
        var working = " " + text.lowercased().replacingOccurrences(of: "-", with: " ") + " "
        working = working.replacingOccurrences(of: #"half an hour|half hour"#, with: "30 minutes", options: .regularExpression)
        working = working.replacingOccurrences(of: #"(a )?quarter (of an )?hour"#, with: "15 minutes", options: .regularExpression)
        working = working.replacingOccurrences(of: #"\b(an|a) (hour|minute|second)"#, with: "1 $2", options: .regularExpression)
        // Longest number words first so "twenty five" wins over "twenty".
        for (word, value) in numberWords.sorted(by: { $0.key.count > $1.key.count }) {
            working = working.replacingOccurrences(of: #"\b\#(word)\b"#, with: formatted(value), options: .regularExpression)
        }

        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)\s*"# + unitPattern + #"(\s+and\s+a\s+half)?"#) else {
            return nil
        }
        var total: TimeInterval = 0
        var found = false
        let range = NSRange(working.startIndex..., in: working)
        for match in regex.matches(in: working, range: range) {
            guard let numberRange = Range(match.range(at: 1), in: working),
                  let unitRange = Range(match.range(at: 2), in: working),
                  let number = Double(working[numberRange].replacingOccurrences(of: ",", with: ".")) else { continue }
            let unit = working[unitRange]
            let multiplier: Double = unit.hasPrefix("h") ? 3600 : unit.hasPrefix("m") ? 60 : 1
            var value = number
            if match.range(at: 3).location != NSNotFound { value += 0.5 }
            total += value * multiplier
            found = true
        }
        return found && total > 0 ? total : nil
    }

    /// "1 h 5 min", "90 s" → human readable ("1 hour 5 minutes").
    public static func describe(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
        if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
        if secs > 0 && hours == 0 { parts.append("\(secs) \(secs == 1 ? "second" : "seconds")") }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }

    /// Countdown text: "4:59" or "1:02:03".
    public static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    private static func formatted(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

/// A small, safe arithmetic evaluator (no `NSExpression`, which can invoke arbitrary
/// selectors). Supports + − × ÷ ^ %, parentheses, unary minus, sqrt and "x% of y".
public enum Calculator {
    public enum CalcError: Error, Equatable { case invalid, divisionByZero }

    /// Converts spoken math ("5 times 3 plus 2") into symbols.
    public static func normalize(_ text: String) -> String {
        var expression = " " + text.lowercased() + " "
        let replacements: [(String, String)] = [
            (#"\bdivided by\b"#, "/"), (#"\bover\b"#, "/"), (#"\btimes\b"#, "*"), (#"\bmultiplied by\b"#, "*"),
            (#"\bplus\b"#, "+"), (#"\bminus\b"#, "-"), (#"\bto the power of\b"#, "^"), (#"\bsquared\b"#, "^2"),
            (#"\bsquare root of\b"#, "sqrt"), (#"(\d)\s*x\s*(\d)"#, "$1*$2"), ("×", "*"), ("÷", "/"), ("−", "-"),
            (#"(\d+(?:\.\d+)?)\s*(%|percent)\s*of\s*"#, "$1/100*"),
        ]
        for (pattern, replacement) in replacements {
            expression = expression.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return expression.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// True when the text is plausibly an arithmetic expression (digits and at least one operator).
    public static func looksLikeMath(_ text: String) -> Bool {
        guard let tokens = try? tokenize(normalize(text)) else { return false }
        let hasNumber = tokens.contains { if case .number = $0 { return true } else { return false } }
        let hasOperator = tokens.contains {
            switch $0 {
            case .op, .sqrt: return true
            default: return false
            }
        }
        return hasNumber && hasOperator
    }

    public static func evaluate(_ text: String) throws -> Double {
        var parser = Parser(tokens: try tokenize(normalize(text)))
        let value = try parser.parseExpression()
        guard parser.isAtEnd, value.isFinite else { throw CalcError.invalid }
        return value
    }

    public static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 6
        formatter.minimumFractionDigits = 0
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    enum Token: Equatable { case number(Double), op(Character), open, close, sqrt }

    static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char.isWhitespace { index = text.index(after: index); continue }
            if char.isNumber || char == "." {
                var end = index
                while end < text.endIndex, text[end].isNumber || text[end] == "." { end = text.index(after: end) }
                guard let value = Double(text[index..<end]) else { throw CalcError.invalid }
                tokens.append(.number(value))
                index = end
                continue
            }
            if text[index...].hasPrefix("sqrt") {
                tokens.append(.sqrt)
                index = text.index(index, offsetBy: 4)
                continue
            }
            switch char {
            case "+", "-", "*", "/", "^", "%": tokens.append(.op(char))
            case "(": tokens.append(.open)
            case ")": tokens.append(.close)
            default: throw CalcError.invalid
            }
            index = text.index(after: index)
        }
        return tokens
    }

    /// Recursive-descent parser: expression → term (+|- term)*, term → power (*|/ power)*,
    /// power → unary (^ power)?, unary → -unary | primary (%)?
    struct Parser {
        let tokens: [Token]
        var position = 0
        var isAtEnd: Bool { position >= tokens.count }

        init(tokens: [Token]) { self.tokens = tokens }

        mutating func parseExpression() throws -> Double {
            var value = try parseTerm()
            while case .op(let op)? = peek(), op == "+" || op == "-" {
                position += 1
                let rhs = try parseTerm()
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func parseTerm() throws -> Double {
            var value = try parsePower()
            while case .op(let op)? = peek(), op == "*" || op == "/" {
                position += 1
                let rhs = try parsePower()
                if op == "/" {
                    guard rhs != 0 else { throw CalcError.divisionByZero }
                    value /= rhs
                } else {
                    value *= rhs
                }
            }
            return value
        }

        mutating func parsePower() throws -> Double {
            let base = try parseUnary()
            if case .op("^")? = peek() {
                position += 1
                return pow(base, try parsePower())
            }
            return base
        }

        mutating func parseUnary() throws -> Double {
            if case .op("-")? = peek() { position += 1; return -(try parseUnary()) }
            if case .op("+")? = peek() { position += 1; return try parseUnary() }
            var value = try parsePrimary()
            if case .op("%")? = peek() { position += 1; value /= 100 }
            return value
        }

        mutating func parsePrimary() throws -> Double {
            guard let token = peek() else { throw CalcError.invalid }
            position += 1
            switch token {
            case .number(let value): return value
            case .open:
                let value = try parseExpression()
                guard peek() == .close else { throw CalcError.invalid }
                position += 1
                return value
            case .sqrt:
                let value = try parseUnary()
                guard value >= 0 else { throw CalcError.invalid }
                return value.squareRoot()
            default:
                throw CalcError.invalid
            }
        }

        func peek() -> Token? { position < tokens.count ? tokens[position] : nil }
    }
}
