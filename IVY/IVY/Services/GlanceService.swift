import AppKit
import Combine
import EventKit
import IVYCore

/// The dashboard's "at a glance" lines: today's reminders, the next event, battery, unread
/// mail and the active Focus, shown on hover without asking.
///
/// Refreshes only while the dashboard opens. It never triggers a permission prompt and never
/// launches an app: each source is skipped unless access was already granted (and, for Mail,
/// unless Mail is already running).
@MainActor
final class GlanceService: ObservableObject {
    struct Item: Identifiable, Equatable {
        var id: String
        var symbol: String
        var text: String
        var tint: Tint = .neutral
        /// What IVY is asked when the line is clicked.
        var query: String?

        enum Tint: Equatable { case neutral, orange, red, green, purple }
    }

    @Published private(set) var items: [Item] = []

    private let settings: SettingsStore
    private let reminders: ReminderService
    private let calendar: CalendarService
    private let mail: MailService
    private let focus: FocusService
    private let energy: EnergyMonitor
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh: Date = .distantPast

    init(settings: SettingsStore, reminders: ReminderService, calendar: CalendarService, mail: MailService,
         focus: FocusService, energy: EnergyMonitor) {
        self.settings = settings
        self.reminders = reminders
        self.calendar = calendar
        self.mail = mail
        self.focus = focus
        self.energy = energy
    }

    func refresh(force: Bool = false) {
        guard settings.bool(.showGlance) else {
            items = []
            return
        }
        // Hovering in and out repeatedly shouldn't hit EventKit and Mail each time.
        guard force || Date().timeIntervalSince(lastRefresh) > 30 else { return }
        lastRefresh = Date()
        energy.refresh()
        refreshTask?.cancel()
        refreshTask = Task {
            let collected = await collect()
            guard !Task.isCancelled else { return }
            items = collected
        }
    }

    private func collect() async -> [Item] {
        var result: [Item] = []
        let now = Date()

        // Reminders due today (+ overdue).
        if settings.dashboardWidgets.contains(.reminders), reminders.hasAccess, let due = try? await reminders.reminders(scope: .today, now: now) {
            let count = due.items.count
            let overdue = due.overdue
            let text = count == 0 ? "No reminders today"
                : "\(count) reminder\(count == 1 ? "" : "s") today\(overdue > 0 ? " · \(overdue) overdue" : "")"
            result.append(Item(id: "reminders", symbol: "checklist", text: text, tint: overdue > 0 ? .red : .orange,
                               query: "What's on my to-do list today?"))
        } else if settings.dashboardWidgets.contains(.reminders) {
            result.append(Item(id: "reminders", symbol: "checklist", text: "Today's to-dos", tint: .orange,
                               query: "What's on my to-do list today?"))
        }

        // Next event today.
        if settings.dashboardWidgets.contains(.event), calendar.authorizationStatus == .fullAccess, let events = try? await calendar.events(scope: "today", now: now),
           let next = events.first(where: { !$0.isAllDay && $0.end > now }) {
            let time = next.start <= now ? "now" : next.start.formatted(date: .omitted, time: .shortened)
            result.append(Item(id: "event", symbol: "calendar", text: "\(next.title) · \(time)", tint: .red,
                               query: "What's on my calendar today?"))
        }

        // Unread mail, only when Mail is already open and IVY may already talk to it.
        if settings.dashboardWidgets.contains(.mail), settings.bool(.mailOnDashboard), mail.isRunning {
            let status = await Task.detached(priority: .utility) {
                PermissionService.automationStatus(bundleID: MailService.bundleID)
            }.value
            if status == .granted, let unread = try? await mail.unreadCount(), unread > 0 {
                result.append(Item(id: "mail", symbol: "envelope.badge", text: "\(unread) unread email\(unread == 1 ? "" : "s")",
                                   tint: .neutral, query: "Any new mail?"))
            }
        }

        // Focus.
        if settings.dashboardWidgets.contains(.focus), let name = focus.activeName {
            result.append(Item(id: "focus", symbol: "moon.fill", text: "\(name) Focus", tint: .purple, query: "What focus is on?"))
        }

        // Battery / heat.
        let snapshot = energy.snapshot
        if snapshot.thermal == .serious || snapshot.thermal == .critical {
            result.append(Item(id: "thermal", symbol: "thermometer.high", text: "Mac is hot · models unload sooner",
                               tint: .red, query: "How's my battery?"))
        } else if let percent = snapshot.percent {
            let state = snapshot.isCharging ? " · charging" : snapshot.onBattery && percent <= 20 ? " · charge soon" : ""
            result.append(Item(id: "battery", symbol: snapshot.isCharging ? "battery.100percent.bolt" : "battery.50percent",
                               text: "Battery \(percent)%\(state)",
                               tint: snapshot.onBattery && percent <= 20 ? .red : .green, query: "How's my battery?"))
        }
        let selected = settings.dashboardWidgets
        return selected.compactMap { widget in
            result.first { $0.id == widget.rawValue || (widget == .battery && $0.id == "thermal") }
        }
    }
}
