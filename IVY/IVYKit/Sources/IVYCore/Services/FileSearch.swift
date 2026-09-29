import Foundation

/// File types IVY can filter Spotlight results by.
public enum FileKind: String, CaseIterable, Sendable, Codable {
    case any, folder, pdf, image, document, spreadsheet, presentation, audio, video, code, archive, app

    /// Uniform Type Identifiers matched against `kMDItemContentTypeTree`.
    public var contentTypes: [String] {
        switch self {
        case .any: return []
        case .folder: return ["public.folder"]
        case .pdf: return ["com.adobe.pdf"]
        case .image: return ["public.image"]
        case .document: return ["public.text", "public.composite-content", "com.apple.iwork.pages.sffpages"]
        case .spreadsheet: return ["public.spreadsheet", "com.apple.iwork.numbers.sffnumbers"]
        case .presentation: return ["public.presentation", "com.apple.iwork.keynote.sffkey"]
        case .audio: return ["public.audio"]
        case .video: return ["public.movie"]
        case .code: return ["public.source-code", "public.script"]
        case .archive: return ["public.archive"]
        case .app: return ["com.apple.application-bundle"]
        }
    }

    /// Plural noun for summaries ("PDFs", "images").
    public var plural: String {
        switch self {
        case .any: return "files"
        case .folder: return "folders"
        case .pdf: return "PDFs"
        case .image: return "images"
        case .document: return "documents"
        case .spreadsheet: return "spreadsheets"
        case .presentation: return "presentations"
        case .audio: return "audio files"
        case .video: return "videos"
        case .code: return "code files"
        case .archive: return "archives"
        case .app: return "apps"
        }
    }

    static let words: [String: FileKind] = [
        "file": .any, "files": .any,
        "folder": .folder, "folders": .folder, "directory": .folder, "directories": .folder,
        "pdf": .pdf, "pdfs": .pdf,
        "image": .image, "images": .image, "photo": .image, "photos": .image, "picture": .image, "pictures": .image,
        "screenshot": .image, "screenshots": .image,
        "document": .document, "documents": .document, "doc": .document, "docs": .document,
        "spreadsheet": .spreadsheet, "spreadsheets": .spreadsheet, "excel": .spreadsheet, "sheet": .spreadsheet,
        "sheets": .spreadsheet,
        "presentation": .presentation, "presentations": .presentation, "slides": .presentation, "keynote": .presentation,
        "deck": .presentation, "powerpoint": .presentation,
        "song": .audio, "songs": .audio, "audio": .audio, "recording": .audio, "recordings": .audio,
        "video": .video, "videos": .video, "movie": .video, "movies": .video,
        "script": .code, "scripts": .code,
        "zip": .archive, "zips": .archive, "archive": .archive, "archives": .archive,
        "app": .app, "apps": .app, "application": .app, "applications": .app,
    ]

    /// Maps a spoken word ("pdfs", "photos") to a kind.
    public static func from(word: String) -> FileKind? {
        if let kind = FileKind(rawValue: word.lowercased()) { return kind }
        return words[word.lowercased()]
    }
}

/// Relative modification-date windows ("from yesterday", "this week").
public enum DateWindow: String, CaseIterable, Sendable, Codable {
    case today, yesterday
    case thisWeek = "this_week"
    case lastWeek = "last_week"
    case thisMonth = "this_month"
    case last7Days = "last_7_days"
    case last30Days = "last_30_days"
    case thisYear = "this_year"

    public var phrase: String {
        switch self {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .thisWeek: return "this week"
        case .lastWeek: return "last week"
        case .thisMonth: return "this month"
        case .last7Days: return "in the last 7 days"
        case .last30Days: return "in the last 30 days"
        case .thisYear: return "this year"
        }
    }

    /// Accepts enum values and everyday phrases.
    public static func parse(_ raw: String) -> DateWindow? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(from|since|modified|changed|edited|created|of)\s+"#, with: "", options: .regularExpression)
        if let window = DateWindow(rawValue: text.replacingOccurrences(of: " ", with: "_")) { return window }
        switch text {
        case "today", "this morning", "this afternoon", "tonight": return .today
        case "yesterday": return .yesterday
        case "this week": return .thisWeek
        case "last week", "the last week", "past week": return .lastWeek
        case "this month": return .thisMonth
        case "recently", "lately", "the last few days", "the past few days", "last few days", "past few days",
             "the last 7 days", "last 7 days", "the past 7 days": return .last7Days
        case "last month", "the last month", "past month", "the last 30 days", "last 30 days": return .last30Days
        case "this year": return .thisYear
        default: return nil
        }
    }

    /// Start (inclusive) and end (exclusive, nil = now) of the window.
    public func range(now: Date, calendar: Calendar = .current) -> (start: Date, end: Date?) {
        let today = calendar.startOfDay(for: now)
        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        switch self {
        case .today: return (today, nil)
        case .yesterday: return (calendar.date(byAdding: .day, value: -1, to: today)!, today)
        case .thisWeek: return (week, nil)
        case .lastWeek: return (calendar.date(byAdding: .day, value: -7, to: week)!, week)
        case .thisMonth: return (calendar.dateInterval(of: .month, for: now)?.start ?? today, nil)
        case .last7Days: return (calendar.date(byAdding: .day, value: -7, to: now)!, nil)
        case .last30Days: return (calendar.date(byAdding: .day, value: -30, to: now)!, nil)
        case .thisYear: return (calendar.dateInterval(of: .year, for: now)?.start ?? today, nil)
        }
    }
}

/// A structured Spotlight query: name words, kind, date window and folder.
public struct FileSearchRequest: Sendable, Equatable {
    public var name: String?
    public var kind: FileKind
    public var modified: DateWindow?
    /// A known folder name ("downloads") or a ~/absolute path.
    public var folder: String?

    public init(name: String? = nil, kind: FileKind = .any, modified: DateWindow? = nil, folder: String? = nil) {
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.kind = kind
        self.modified = modified
        self.folder = folder?.nilIfEmpty
    }

    /// A search needs at least one real constraint; "find files" alone would list the whole disk.
    public var isSpecific: Bool { name != nil || kind != .any || modified != nil }

    /// Spotlight predicate. Every name word must appear in the file name (case/diacritic-insensitive).
    public func predicate(now: Date = Date(), calendar: Calendar = .current) -> NSPredicate {
        var parts: [NSPredicate] = []
        let words = (name ?? "").split(whereSeparator: \.isWhitespace).map(String.init).prefix(6)
        for word in words {
            parts.append(NSPredicate(format: "%K LIKE[cd] %@", "kMDItemFSName", "*\(word)*"))
        }
        let types = kind.contentTypes
        if !types.isEmpty {
            parts.append(NSCompoundPredicate(orPredicateWithSubpredicates: types.map {
                NSPredicate(format: "%K == %@", "kMDItemContentTypeTree", $0)
            }))
        }
        if let modified {
            let range = modified.range(now: now, calendar: calendar)
            parts.append(NSPredicate(format: "%K >= %@", "kMDItemFSContentChangeDate", range.start as NSDate))
            if let end = range.end {
                parts.append(NSPredicate(format: "%K < %@", "kMDItemFSContentChangeDate", end as NSDate))
            }
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    /// "Found 3 PDFs named “invoice” from last week."
    public func summary(count: Int) -> String {
        var what = kind.plural
        if let name { what += " named “\(name)”" }
        if let modified { what += " \(modified == .today || modified == .yesterday ? "from " : "")\(modified.phrase)" }
        if let folder { what += " in \(folder.capitalizedFirstWord)" }
        switch count {
        case 0: return "No \(what)."
        case 1: return "Found 1 match for \(what)."
        default: return "Found \(count) \(what)."
        }
    }

    // MARK: - Natural language

    /// "find the budget spreadsheet from last week", "where is my tax return pdf",
    /// "search my downloads for zip files", "find files named invoice".
    public static func parse(_ normalized: String) -> FileSearchRequest? {
        var text = normalized
        var folder: String?

        // "search my downloads for …" / "look in documents for …"
        let folderNames = CommandRouter.knownFolders.keys.sorted().joined(separator: "|")
        if let match = text.firstMatch(#"^(?:search|look in|look through|check)( my| the)? (\#(folderNames))( folder)? for (.+)$"#) {
            folder = match[2]
            text = "find " + match[4]
        }

        guard let verbMatch = text.firstMatch(#"^(find|search for|search|look for|locate|where is|where's|where are)( me)? (.+)$"#) else {
            return nil
        }
        var rest = verbMatch[3]

        // Trailing folder: "… in my downloads (folder)"
        if let match = rest.firstMatch(#"^(.+?) (?:in|from|inside) (?:my |the )?(\#(folderNames))(?: folder)?$"#) {
            rest = match[1]
            folder = match[2]
        }
        // Trailing date: "… from last week", "… modified today"
        var modified: DateWindow?
        if let match = rest.firstMatch(#"^(.+?) (?:(?:that i |i )?(?:modified|changed|edited|created|saved|downloaded|made|worked on) |from |since )?(today|yesterday|this week|last week|this month|last month|this year|recently|lately|(?:the )?(?:last|past) (?:few|7|30) days)$"#) {
            rest = match[1]
            modified = DateWindow.parse(match[2])
        }

        var name: String?
        if let match = rest.firstMatch(#"^(.*?)\s*(?:named|called|titled|with the name|with)\s+["“']?(.+?)["”']?(?: in (?:the |its )?name)?$"#) {
            rest = match[1]
            name = match[2]
        }

        // What's left: "[my|the|all] [name words] <kind word>" or "<kind word>".
        var words = rest.split(separator: " ").map(String.init)
        words.removeAll { ["a", "an", "the", "my", "all", "any", "some", "of", "that", "those", "these"].contains($0) }
        var kind: FileKind?
        if let last = words.last, let found = FileKind.from(word: last) {
            kind = found
            words.removeLast()
            if found == .any || words.last.flatMap(FileKind.from(word:)) != nil {
                // "pdf files" → pdf
                if let previous = words.last, let specific = FileKind.from(word: previous), specific != .any {
                    kind = specific
                    words.removeLast()
                }
            }
        } else if let first = words.first, let found = FileKind.from(word: first), found != .any {
            // "pdfs about taxes" is rare; accept "pdfs" only as a whole phrase.
            kind = found
            words.removeFirst()
            if words.first == "files" { words.removeFirst() }
            if !words.isEmpty { return nil }
        }
        // Without a kind word, only an explicit "named …" makes this a file search.
        guard kind != nil || name != nil else { return nil }
        if name == nil, !words.isEmpty {
            // Name words in front of the kind: "the budget spreadsheet".
            guard words.count <= 4 else { return nil }
            name = words.joined(separator: " ")
        }
        let request = FileSearchRequest(name: name, kind: kind ?? .any, modified: modified, folder: folder)
        return request.isSpecific ? request : nil
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var capitalizedFirstWord: String { prefix(1).uppercased() + dropFirst() }

    /// Capture groups of the first regex match (index 0 = whole match; missing groups = "").
    func firstMatch(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: self).map { String(self[$0]) } ?? ""
        }
    }
}
