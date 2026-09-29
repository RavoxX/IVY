import Foundation
import IVYCore

struct RemindersListTool: IVYTool {
    let service: ReminderService
    let name = ToolName.remindersList
    let description = "List the user's Apple Reminders (to-do list). Use for any question about tasks, to-dos or reminders."
    let displayName = "Reminders"
    let baseRisk = RiskLevel.low
    let isTerminal = false
    var parameters: [ToolParameter] {
        [ToolParameter("scope", .string, "Which reminders: today (default), overdue, upcoming (next 7 days) or all open ones.",
                       enumValues: ReminderScope.allCases.map(\.rawValue))]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let scope = arguments.string("scope").flatMap { ReminderScope(rawValue: $0.lowercased()) } ?? .today
        let (items, overdue) = try await service.reminders(scope: scope, now: context.now)
        let summary = ReminderTransforms.summary(for: items, scope: scope, overdueCount: overdue)
        let lines = items.prefix(15).map { JSONValue.string(ReminderTransforms.line(for: $0)) }
        return ToolResult(summary: summary,
                          data: ["reminders": .array(Array(lines)), "overdue_count": .number(Double(overdue))],
                          card: items.isEmpty ? nil : .reminders(title: scope.title, items: items),
                          historyTitle: "Daily Reminder Overview")
    }
}

struct RemindersCreateTool: IVYTool {
    let service: ReminderService
    let name = ToolName.remindersCreate
    let description = "Create a new reminder in Apple Reminders."
    let displayName = "Reminders"
    let baseRisk = RiskLevel.medium
    var parameters: [ToolParameter] {
        [
            ToolParameter("title", .string, "What to be reminded about, e.g. 'Call Alex'.", required: true),
            ToolParameter("due", .string, "When, in the user's own words (e.g. 'tomorrow at 5pm') or ISO-8601. Omit if no time was given."),
            ToolParameter("notes", .string, "Optional extra notes."),
            ToolParameter("list", .string, "Optional Reminders list name."),
        ]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let title = try arguments.requiredString("title")
        guard title.count <= 300 else { throw ToolError.invalidArgument("title", "too long") }
        var due: NaturalDateParser.ParsedDate?
        if let raw = arguments.string("due") {
            due = NaturalDateParser.parse(raw, now: context.now)
            if due == nil { throw ToolError.invalidArgument("due", "I couldn't understand the time '\(raw)'.") }
        }
        let item = try await service.create(title: title, due: due, notes: arguments.string("notes"),
                                            listName: arguments.string("list"))
        let when = item.dueDate.map { " for \(Self.describe($0, hasTime: item.hasDueTime))" } ?? ""
        return ToolResult(summary: "Reminder set: \(item.title)\(when).",
                          card: .reminders(title: "New Reminder", items: [item]),
                          historyTitle: "New Reminder")
    }

    static func describe(_ date: Date, hasTime: Bool) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        let day: String
        if calendar.isDateInToday(date) { day = "today" }
        else if calendar.isDateInTomorrow(date) { day = "tomorrow" }
        else { day = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }
        return hasTime ? "\(day) at \(time)" : day
    }
}

struct RemindersCompleteTool: IVYTool {
    let service: ReminderService
    let name = ToolName.remindersComplete
    let description = "Mark an existing reminder as completed."
    let displayName = "Reminders"
    let baseRisk = RiskLevel.medium
    var parameters: [ToolParameter] {
        [ToolParameter("title", .string, "Title (or part of it) of the reminder to complete.", required: true)]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let query = try arguments.requiredString("title")
        let open = try await service.incompleteReminders()
        if let options = ReminderTransforms.ambiguousMatches(for: query, in: open) {
            let names = options.map { "“\($0.title)”" }
            return .question("Which one: \(MailSearchTool.list(names))?", historyTitle: "Completed Reminder")
        }
        guard let match = ReminderTransforms.bestMatch(for: query, in: open) else {
            return .failure("I couldn't find an open reminder matching “\(query)”.")
        }
        let completed = try await service.complete(id: match.id)
        return ToolResult(summary: "Marked “\(completed.title)” as done.", historyTitle: "Completed Reminder")
    }
}

struct RemindersSearchTool: IVYTool {
    let service: ReminderService
    let name = ToolName.remindersSearch
    let description = "Search open reminders by text."
    let displayName = "Reminders"
    let baseRisk = RiskLevel.low
    let isTerminal = false
    var parameters: [ToolParameter] {
        [ToolParameter("query", .string, "Text to search for.", required: true)]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let query = try arguments.requiredString("query")
        let items = ReminderTransforms.sort(try await service.search(query))
        let summary = items.isEmpty ? "No reminders match “\(query)”."
            : "Found \(ReminderTransforms.countWord(items.count)) \(items.count == 1 ? "reminder" : "reminders")."
        return ToolResult(summary: summary,
                          data: ["reminders": .array(items.prefix(15).map { .string(ReminderTransforms.line(for: $0)) })],
                          card: items.isEmpty ? nil : .reminders(title: "Search Results", items: items),
                          historyTitle: "Reminder Search")
    }
}
