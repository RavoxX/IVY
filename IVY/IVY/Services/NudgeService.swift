import AppKit
import Combine
import EventKit
import IVYCore
import os

/// Proactive notices on the notch: "Standup in 10 min", "Battery at 15%", "Mac is very hot".
///
/// Event-driven with no polling: one timer for the next event (replanned when the calendar
/// changes and once an hour), and the energy monitor's published snapshot for battery and
/// heat. Calendar notices only run when calendar access was already granted, and they stay
/// silent during Sleep / Do Not Disturb.
@MainActor
final class NudgeService {
    struct Nudge: Equatable {
        var symbol: String
        var text: String
    }

    var onNudge: ((Nudge) -> Void)?
    private let settings: SettingsStore
    private let calendar: CalendarService
    private let energy: EnergyMonitor
    private let focus: FocusService
    private var eventTimer: Timer?
    private var hourly: Timer?
    private var announcedEvents: Set<String> = []
    private var batteryNudged = false
    private var thermalNudged = false
    private var cancellables: Set<AnyCancellable> = []
    static let leadTime: TimeInterval = 10 * 60

    init(settings: SettingsStore, calendar: CalendarService, energy: EnergyMonitor, focus: FocusService) {
        self.settings = settings
        self.calendar = calendar
        self.energy = energy
        self.focus = focus
    }

    func start() {
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.replan() }
            .store(in: &cancellables)
        energy.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in self?.check(snapshot) }
            .store(in: &cancellables)
        hourly = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.replan() }
        }
        replan()
    }

    // MARK: - Calendar

    func replan() {
        eventTimer?.invalidate()
        eventTimer = nil
        guard settings.bool(.proactiveNudges), calendar.authorizationStatus == .fullAccess else { return }
        Task { [weak self] in
            guard let self else { return }
            let now = Date()
            var upcoming = (try? await calendar.events(scope: "today", now: now)) ?? []
            upcoming += (try? await calendar.events(scope: "tomorrow", now: now)) ?? []
            guard let next = upcoming
                .filter({ !$0.isAllDay && $0.start > now && !self.announcedEvents.contains($0.id) })
                .min(by: { $0.start < $1.start }) else { return }
            let fireDate = max(now.addingTimeInterval(1), next.start.addingTimeInterval(-Self.leadTime))
            let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.announce(next) }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            self.eventTimer = timer
        }
    }

    private func announce(_ event: CalendarEventItem) {
        announcedEvents.insert(event.id)
        defer { replan() }
        guard settings.bool(.proactiveNudges), event.start > Date() else { return }
        if let name = focus.activeName, FocusParser.isQuiet(name) { return }
        let minutes = max(1, Int((event.start.timeIntervalSinceNow / 60).rounded()))
        let place = event.location.map { " · \($0)" } ?? ""
        onNudge?(Nudge(symbol: "calendar", text: "\(event.title) in \(minutes) min\(place)"))
    }

    // MARK: - Energy

    private func check(_ snapshot: EnergySnapshot) {
        guard settings.bool(.proactiveNudges) else { return }
        if snapshot.isPluggedIn { batteryNudged = false }
        if snapshot.onBattery, let percent = snapshot.percent, percent <= 15, !batteryNudged {
            batteryNudged = true
            let left = snapshot.minutesRemaining.map { ", about \(EnergyAdvisor.durationText($0)) left" } ?? ""
            onNudge?(Nudge(symbol: "battery.25percent", text: "Battery at \(percent)%\(left). Charge soon."))
        }
        if snapshot.thermal == .critical, !thermalNudged {
            thermalNudged = true
            onNudge?(Nudge(symbol: "thermometer.high", text: "Your Mac is very hot. IVY unloaded its models to help it cool down."))
        } else if snapshot.thermal == .nominal || snapshot.thermal == .fair {
            thermalNudged = false
        }
    }
}
