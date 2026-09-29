import Foundation

/// Filters inbox envelopes in Swift. The AppleScript that reads Mail is a fixed template;
/// no user or model text is ever interpolated into it.
public enum MailFilter {
    public static func senderName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let bracket = trimmed.firstIndex(of: "<") {
            let name = trimmed[..<bracket].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !name.isEmpty { return name }
            return trimmed[trimmed.index(after: bracket)...].trimmingCharacters(in: CharacterSet(charactersIn: "> "))
        }
        return trimmed
    }

    public static func filter(_ items: [MailMessageItem], from sender: String? = nil, query: String? = nil,
                              unreadOnly: Bool = false, since: Date? = nil) -> [MailMessageItem] {
        let senderWords = words(sender)
        let queryWords = words(query)
        return items
            .filter { !unreadOnly || !$0.isRead }
            .filter { since == nil || $0.date >= since! }
            .filter { item in
                let haystack = fold(item.sender)
                return senderWords.allSatisfy { haystack.contains($0) }
            }
            .filter { item in
                let haystack = fold(item.subject + " " + item.sender)
                return queryWords.allSatisfy { haystack.contains($0) }
            }
            .sorted { $0.date > $1.date }
    }

    public static func summary(for items: [MailMessageItem], from sender: String?, query: String?, unreadOnly: Bool) -> String {
        let noun = unreadOnly ? "unread email" : "email"
        var scope = ""
        if let sender { scope += " from \(sender.capitalizedFirstWord)" }
        if let query { scope += " about “\(query)”" }
        guard let first = items.first else {
            return unreadOnly && sender == nil && query == nil ? "No unread email in your inbox." : "No \(noun)s\(scope) in your recent inbox."
        }
        let count = items.count == 1 ? "one \(noun)" : "\(ReminderTransforms.countWord(items.count)) \(noun)s"
        let latestFrom = sender == nil ? " from \(first.senderName)" : ""
        let latest = first.subject.isEmpty ? "" : " Latest\(latestFrom): “\(first.subject)”."
        return "You have \(count)\(scope).\(latest)"
    }

    private static func words(_ text: String?) -> [String] {
        guard let text else { return [] }
        return fold(text).split(separator: " ").map(String.init).filter { $0.count > 1 }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"[^\p{L}\p{N}@.]+"#, with: " ", options: .regularExpression)
    }

    // MARK: - Natural language

    public struct Request: Equatable, Sendable {
        public var from: String?
        public var query: String?
        public var unreadOnly: Bool
    }

    /// "any new mail from Alex?", "search for invoice in my inbox", "check my email".
    public static func parse(_ normalized: String) -> Request? {
        let text = normalized
        let mail = #"(?:e-?mails?|mails?|messages in my inbox)"#
        if let match = text.firstMatch(#"^(?:do i have |did i get |have i got |are there |is there |check for |any )+(?:any )?(new |unread )?\#(mail) from (.+)$"#) {
            return Request(from: match[2], query: nil, unreadOnly: !match[1].isEmpty)
        }
        if let match = text.firstMatch(#"^(?:show|list|find|get)(?: me)?(?: the| my)?( new| unread| latest| recent)? \#(mail) from (.+)$"#) {
            return Request(from: match[2], query: nil, unreadOnly: match[1].contains("new") || match[1].contains("unread"))
        }
        if let match = text.firstMatch(#"^(?:search|look)(?: for)? (.+?) in (?:my |the )?(?:inbox|mail|email|e-mail|emails)$"#) {
            return Request(from: nil, query: match[1], unreadOnly: false)
        }
        if let match = text.firstMatch(#"^(?:search|check) (?:my |the )?(?:inbox|mail|email|emails) for (.+)$"#) {
            return Request(from: nil, query: match[1], unreadOnly: false)
        }
        if text.range(of: #"^((do i have|did i get|have i got|are there|any) )+(any )?(new|unread) \#(mail)$"#, options: .regularExpression) != nil
            || text.range(of: #"^(check|read) (my )?(mail|email|e-mail|emails|inbox)$"#, options: .regularExpression) != nil
            || text.range(of: #"^how many (new |unread )\#(mail)( do i have)?$"#, options: .regularExpression) != nil
            || text.range(of: #"^(any|new) (mail|email|emails)$"#, options: .regularExpression) != nil {
            return Request(from: nil, query: nil, unreadOnly: true)
        }
        return nil
    }
}
