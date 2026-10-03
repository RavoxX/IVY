import AppKit
import Combine
import EventKit
import IVYCore
import os

/// Countdown timers and alarms that live in the notch. A single `Timer` is scheduled for
/// the next deadline only, so idle cost is zero; the closed notch shows the countdown.
@MainActor
final class TimerService: ObservableObject {
    @Published private(set) var timers: [TimerInfo] = []
    @Published private(set) var ringing: TimerInfo?

    var onFire: ((TimerInfo) -> Void)?
    private var scheduled: Timer?
    private var alertSound: NSSound?
    private var alertStop: DispatchWorkItem?

    var next: TimerInfo? { timers.min { $0.endDate < $1.endDate } }

    @discardableResult
    func start(duration: TimeInterval, label: String?) -> TimerInfo {
        let timer = TimerInfo(label: label, endDate: Date().addingTimeInterval(duration), duration: duration, isAlarm: false)
        add(timer)
        return timer
    }

    @discardableResult
    func alarm(at date: Date, label: String?) -> TimerInfo {
        let timer = TimerInfo(label: label, endDate: date, duration: date.timeIntervalSinceNow, isAlarm: true)
        add(timer)
        return timer
    }

    /// Cancels timers whose label matches, or all timers when `label` is nil.
    @discardableResult
    func cancel(label: String? = nil) -> Int {
        let before = timers.count
        if let label, !label.isEmpty {
            timers.removeAll { ($0.label ?? "").localizedCaseInsensitiveContains(label) }
        } else {
            timers.removeAll()
        }
        reschedule()
        return before - timers.count
    }

    func cancel(id: UUID) {
        timers.removeAll { $0.id == id }
        reschedule()
    }

    func stopRinging() {
        alertStop?.cancel()
        alertSound?.stop()
        alertSound = nil
        ringing = nil
    }

    private func add(_ timer: TimerInfo) {
        timers.append(timer)
        timers.sort { $0.endDate < $1.endDate }
        reschedule()
        Log.tools.info("Timer scheduled in \(Int(timer.remaining())) s")
    }

    private func reschedule() {
        scheduled?.invalidate()
        guard let next else { return }
        let timer = Timer(fire: next.endDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireDue() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        scheduled = timer
    }

    private func fireDue() {
        let now = Date().addingTimeInterval(0.1)
        let due = timers.filter { $0.endDate <= now }
        timers.removeAll { $0.endDate <= now }
        reschedule()
        for timer in due {
            ring(timer)
            onFire?(timer)
        }
    }

    /// Plays the alert sound in a loop for up to 30 s, or until stopped.
    private func ring(_ timer: TimerInfo) {
        stopRinging()
        ringing = timer
        let sound = NSSound(named: "Glass")
        sound?.loops = true
        sound?.volume = 0.8
        sound?.play()
        alertSound = sound
        let stop = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.stopRinging() } }
        alertStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: stop)
    }
}

/// Calendar events through EventKit: read, and create when the user asks.
final class CalendarService: @unchecked Sendable {
    private let store = EKEventStore()

    var authorizationStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    func ensureAccess() async throws -> Bool {
        switch authorizationStatus {
        case .fullAccess: return true
        case .notDetermined: return try await store.requestFullAccessToEvents()
        default: return false
        }
    }

    /// Adds an event to the default calendar. `end` nil = one hour (or the whole day).
    func create(title: String, start: Date, end: Date?, allDay: Bool, location: String?) async throws -> CalendarEventItem {
        guard try await ensureAccess() else { throw ToolError.permissionDenied("Calendar") }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw ToolError.unavailable("No calendar is available for new events.")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.calendar = calendar
        event.isAllDay = allDay
        event.startDate = allDay ? Calendar.current.startOfDay(for: start) : start
        event.endDate = end ?? (allDay ? event.startDate.addingTimeInterval(86_400 - 1) : start.addingTimeInterval(3600))
        event.location = location
        if !allDay { event.addAlarm(EKAlarm(relativeOffset: -600)) }
        try store.save(event, span: .thisEvent, commit: true)
        // Read it back so IVY only reports what's really in the calendar.
        guard let identifier = event.eventIdentifier, store.event(withIdentifier: identifier) != nil else {
            throw ToolError.failed("The calendar didn't keep the event.")
        }
        Log.tools.info("Created calendar event")
        return CalendarEventItem(id: event.eventIdentifier ?? UUID().uuidString, title: title, start: event.startDate,
                                 end: event.endDate, isAllDay: allDay, calendar: calendar.title, location: location)
    }

    func event(id: String) async throws -> CalendarEventItem {
        guard try await ensureAccess(), let event = store.event(withIdentifier: id) else { throw ToolError.failed("That event no longer exists or Calendar access is unavailable.") }
        return Self.item(event)
    }

    func update(id: String, start: Date, duration: TimeInterval?) async throws -> (before: CalendarEventItem, after: CalendarEventItem) {
        guard try await ensureAccess(), let event = store.event(withIdentifier: id) else { throw ToolError.failed("That event no longer exists or Calendar access is unavailable.") }
        guard event.calendar.allowsContentModifications, event.recurrenceRules?.isEmpty != false else {
            throw ToolError.unavailable("This event is read-only or repeats. Edit recurring events in Calendar.")
        }
        let before = Self.item(event)
        let seconds = duration ?? event.endDate.timeIntervalSince(event.startDate)
        event.startDate = start; event.endDate = start.addingTimeInterval(seconds)
        try store.save(event, span: .thisEvent, commit: true)
        guard let updated = store.event(withIdentifier: event.eventIdentifier), updated.startDate == start else { throw ToolError.failed("Calendar didn't keep the changed time.") }
        return (before, Self.item(updated))
    }

    func restore(_ before: CalendarEventItem, ifUnchanged after: CalendarEventItem) async throws -> String {
        guard try await ensureAccess(), let event = store.event(withIdentifier: after.id), Self.item(event) == after else {
            throw ToolError.failed("The event changed after IVY moved it; undo was stopped.")
        }
        event.startDate = before.start; event.endDate = before.end
        try store.save(event, span: .thisEvent, commit: true)
        return "Restored the previous time for “\(before.title)”."
    }

    private static func item(_ event: EKEvent) -> CalendarEventItem {
        CalendarEventItem(id: event.eventIdentifier ?? "", title: event.title ?? "", start: event.startDate,
            end: event.endDate, isAllDay: event.isAllDay, calendar: event.calendar.title, location: event.location)
    }

    func undoCreation(_ original: CalendarEventItem) async throws -> String {
        guard try await ensureAccess(), let event = store.event(withIdentifier: original.id),
              event.title == original.title, event.startDate == original.start, event.endDate == original.end,
              event.location == original.location, event.isAllDay == original.isAllDay,
              event.calendar.title == original.calendar, event.recurrenceRules?.isEmpty != false else {
            throw ToolError.failed("The event was changed or removed since IVY created it; undo was stopped.")
        }
        try store.remove(event, span: .thisEvent, commit: true)
        guard store.event(withIdentifier: original.id) == nil else { throw ToolError.failed("The event couldn't be removed.") }
        return "Removed the calendar event IVY created: \(original.title)."
    }

    func events(scope: String, now: Date = Date()) async throws -> [CalendarEventItem] {
        guard try await ensureAccess() else { throw ToolError.permissionDenied("Calendar") }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let (start, end): (Date, Date)
        switch scope {
        case "tomorrow":
            start = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
            end = calendar.date(byAdding: .day, value: 2, to: startOfToday)!
        case "week":
            start = now
            end = calendar.date(byAdding: .day, value: 7, to: startOfToday)!
        default:
            start = startOfToday
            end = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                CalendarEventItem(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Untitled",
                                  start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                                  calendar: event.calendar?.title ?? "", location: event.location)
            }
    }
}
