import os
import EventKit
import IVYCore

/// Apple Reminders access through EventKit. All answers about reminders come from here —
/// IVY never lets the model invent reminder data.
final class ReminderService: @unchecked Sendable {
    private let store = EKEventStore()

    var authorizationStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }
    var hasAccess: Bool { authorizationStatus == .fullAccess }

    /// Asks for access only when it hasn't been decided yet (no repeated prompts).
    @discardableResult
    func ensureAccess() async throws -> Bool {
        switch authorizationStatus {
        case .fullAccess:
            return true
        case .notDetermined:
            let granted = try await store.requestFullAccessToReminders()
            Log.reminders.info("Reminders access \(granted ? "granted" : "denied", privacy: .public)")
            return granted
        default:
            return false
        }
    }

    private func requireAccess() async throws {
        guard try await ensureAccess() else { throw ToolError.permissionDenied("Reminders") }
    }

    func incompleteReminders() async throws -> [ReminderItem] {
        try await requireAccess()
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).map(Self.item(from:))
                continuation.resume(returning: items)
            }
        }
    }

    func reminders(scope: ReminderScope, now: Date = Date()) async throws -> (items: [ReminderItem], overdue: Int) {
        let all = try await incompleteReminders()
        let items = ReminderTransforms.filter(all, scope: scope, now: now)
        let overdue = scope == .today ? ReminderTransforms.filter(all, scope: .overdue, now: now).count : 0
        return (items, overdue)
    }

    func search(_ query: String) async throws -> [ReminderItem] {
        let needle = query.lowercased()
        return try await incompleteReminders().filter {
            $0.title.lowercased().contains(needle) || ($0.notes?.lowercased().contains(needle) ?? false)
        }
    }

    func create(title: String, due: NaturalDateParser.ParsedDate?, notes: String?, listName: String?) async throws -> ReminderItem {
        try await requireAccess()
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        if let listName, let calendar = store.calendars(for: .reminder)
            .first(where: { $0.title.caseInsensitiveCompare(listName) == .orderedSame }) {
            reminder.calendar = calendar
        } else if let calendar = store.defaultCalendarForNewReminders() {
            reminder.calendar = calendar
        } else {
            throw ToolError.unavailable("No reminders list is available.")
        }
        if let due {
            let units: Set<Calendar.Component> = due.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            var components = Calendar.current.dateComponents(units, from: due.date)
            components.calendar = Calendar.current
            components.timeZone = due.hasTime ? TimeZone.current : nil
            reminder.dueDateComponents = components
            if due.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
        }
        try store.save(reminder, commit: true)
        guard store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) != nil else {
            throw ToolError.failed("Reminders didn't keep the new reminder.")
        }
        Log.reminders.info("Created reminder")
        return Self.item(from: reminder)
    }

    func complete(id: String) async throws -> ReminderItem {
        try await requireAccess()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ToolError.failed("That reminder no longer exists.")
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
        return Self.item(from: reminder)
    }

    func undoCreation(_ original: ReminderItem) async throws -> String {
        try await requireAccess()
        guard let reminder = store.calendarItem(withIdentifier: original.id) as? EKReminder,
              Self.item(from: reminder) == original else {
            throw ToolError.failed("The reminder was changed or removed since IVY created it; undo was stopped.")
        }
        try store.remove(reminder, commit: true)
        guard store.calendarItem(withIdentifier: original.id) == nil else { throw ToolError.failed("The reminder couldn't be removed.") }
        return "Removed the reminder IVY created: \(original.title)."
    }

    func undoCompletion(_ completed: ReminderItem) async throws -> String {
        try await requireAccess()
        guard let reminder = store.calendarItem(withIdentifier: completed.id) as? EKReminder,
              Self.item(from: reminder) == completed else {
            throw ToolError.failed("The reminder has changed since completion; undo was stopped.")
        }
        reminder.isCompleted = false
        try store.save(reminder, commit: true)
        return "Marked “\(completed.title)” as open again."
    }

    static func item(from reminder: EKReminder) -> ReminderItem {
        var dueDate: Date?
        var hasTime = false
        if var components = reminder.dueDateComponents {
            if components.calendar == nil { components.calendar = Calendar.current }
            dueDate = components.date
            hasTime = components.hour != nil
        }
        return ReminderItem(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Untitled",
                            dueDate: dueDate, hasDueTime: hasTime, isCompleted: reminder.isCompleted,
                            listName: reminder.calendar?.title ?? "Reminders", notes: reminder.notes,
                            priority: reminder.priority)
    }
}
