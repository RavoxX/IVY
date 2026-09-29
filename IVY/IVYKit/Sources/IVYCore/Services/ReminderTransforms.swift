import Foundation

/// Pure reminder logic: bucketing by due date, sorting and phrasing. EventKit access lives
/// in the app target; everything here is testable without Reminders permission.
public enum ReminderScope: String, CaseIterable, Sendable {
    case today, overdue, upcoming, all

    public var title: String {
        switch self {
        case .today: return "Today's Reminders"
        case .overdue: return "Overdue"
        case .upcoming: return "Upcoming"
        case .all: return "Reminders"
        }
    }
}

public enum ReminderTransforms {
    /// Filters incomplete reminders into a scope.
    /// * today: due today (any time today)
    /// * overdue: due before now (before today for all-day reminders)
    /// * upcoming: due after today, within `upcomingDays`
    /// * all: every incomplete reminder
    public static func filter(_ items: [ReminderItem], scope: ReminderScope, now: Date,
                              calendar: Calendar = .current, upcomingDays: Int = 7) -> [ReminderItem] {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        let upcomingEnd = calendar.date(byAdding: .day, value: upcomingDays + 1, to: startOfToday)!

        let open = items.filter { !$0.isCompleted }
        let result: [ReminderItem]
        switch scope {
        case .today:
            result = open.filter { item in
                guard let due = item.dueDate else { return false }
                return due >= startOfToday && due < startOfTomorrow
            }
        case .overdue:
            result = open.filter { isOverdue($0, now: now, calendar: calendar) }
        case .upcoming:
            result = open.filter { item in
                guard let due = item.dueDate else { return false }
                return due >= startOfTomorrow && due < upcomingEnd
            }
        case .all:
            result = open
        }
        return sort(result)
    }

    public static func isOverdue(_ item: ReminderItem, now: Date, calendar: Calendar = .current) -> Bool {
        guard !item.isCompleted, let due = item.dueDate else { return false }
        if item.hasDueTime { return due < now }
        return due < calendar.startOfDay(for: now)
    }

    /// Dated reminders first (earliest first), then undated by priority and title.
    public static func sort(_ items: [ReminderItem]) -> [ReminderItem] {
        items.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                if lhs.priority != rhs.priority {
                    // EventKit priority: 1 = high … 9 = low, 0 = none.
                    let lp = lhs.priority == 0 ? 10 : lhs.priority
                    let rp = rhs.priority == 0 ? 10 : rhs.priority
                    return lp < rp
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    public static func countWord(_ count: Int) -> String {
        let words = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return count < words.count ? words[count] : String(count)
    }

    /// "You have three reminders due today." — short, factual and grounded in real data.
    public static func summary(for items: [ReminderItem], scope: ReminderScope, overdueCount: Int = 0) -> String {
        let count = items.count
        let noun = count == 1 ? "reminder" : "reminders"
        var sentence: String
        switch scope {
        case .today:
            sentence = count == 0 ? "Nothing due today." : "You have \(countWord(count)) \(noun) due today."
        case .overdue:
            sentence = count == 0 ? "Nothing is overdue." : "You have \(countWord(count)) overdue \(noun)."
        case .upcoming:
            sentence = count == 0 ? "No upcoming reminders this week." : "You have \(countWord(count)) upcoming \(noun)."
        case .all:
            sentence = count == 0 ? "Your reminders are all done." : "You have \(countWord(count)) open \(noun)."
        }
        if scope == .today, overdueCount > 0 {
            sentence += " \(overdueCount == 1 ? "One is" : "\(countWord(overdueCount).capitalized) are") overdue."
        }
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    /// Compact line for the model / history ("Meeting (7:00 PM)").
    public static func line(for item: ReminderItem, calendar: Calendar = .current) -> String {
        guard let due = item.dueDate else { return item.title }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if item.hasDueTime {
            formatter.dateStyle = calendar.isDateInToday(due) ? .none : .short
            formatter.timeStyle = .short
        } else {
            if calendar.isDateInToday(due) { return item.title }
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        }
        return "\(item.title) (\(formatter.string(from: due)))"
    }

    /// Best match for "complete the homework reminder".
    /// Several open reminders match equally well ("call" → "Call Alex", "Call the bank"): ask.
    public static func ambiguousMatches(for query: String, in items: [ReminderItem]) -> [ReminderItem]? {
        let needle = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !items.contains(where: { $0.title.lowercased() == needle }) else { return nil }
        let containing = items.filter { $0.title.lowercased().contains(needle) }
        return containing.count > 1 ? Array(containing.prefix(3)) : nil
    }

    public static func bestMatch(for query: String, in items: [ReminderItem]) -> ReminderItem? {
        let needle = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if let exact = items.first(where: { $0.title.lowercased() == needle }) { return exact }
        if let contains = items.first(where: { $0.title.lowercased().contains(needle) }) { return contains }
        let queryWords = Set(needle.split(separator: " ").map(String.init).filter { $0.count > 2 })
        let scored = items.map { item -> (ReminderItem, Int) in
            let words = Set(item.title.lowercased().split(separator: " ").map(String.init))
            return (item, queryWords.intersection(words).count)
        }.filter { $0.1 > 0 }
        return scored.max { $0.1 < $1.1 }?.0
    }
}
