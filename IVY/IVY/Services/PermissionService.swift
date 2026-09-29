import AppKit
import AVFoundation
import Combine
import CoreGraphics
import EventKit
import IVYCore

/// Current state of the macOS permissions IVY can use, without triggering prompts.
@MainActor
final class PermissionService: ObservableObject {
    enum Status: Equatable {
        case granted, denied, notDetermined, notApplicable

        var label: String {
            switch self {
            case .granted: return "Granted"
            case .denied: return "Denied"
            case .notDetermined: return "Not requested"
            case .notApplicable: return "Not needed"
            }
        }
    }

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case reminders = "Privacy_Reminders"
        case inputMonitoring = "Privacy_ListenEvent"
        case accessibility = "Privacy_Accessibility"
        case automation = "Privacy_Automation"
        case fullDiskAccess = "Privacy_AllFiles"
    }

    @Published private(set) var microphone: Status = .notDetermined
    @Published private(set) var reminders: Status = .notDetermined
    @Published private(set) var inputMonitoring: Status = .notDetermined
    @Published private(set) var accessibility: Status = .notDetermined
    @Published private(set) var spotifyAutomation: Status = .notDetermined
    @Published private(set) var mailAutomation: Status = .notDetermined

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notDetermined
        default: microphone = .denied
        }
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: reminders = .granted
        case .notDetermined: reminders = .notDetermined
        default: reminders = .denied
        }
        inputMonitoring = CGPreflightListenEventAccess() ? .granted : .notDetermined
        // Accessibility isn't required: IVY uses a listen-only event tap (Input Monitoring).
        accessibility = AXIsProcessTrusted() ? .granted : .notApplicable
        refreshAutomationStatus()
    }

    /// `AEDeterminePermissionToAutomateTarget` talks to tccd synchronously and can block
    /// for a long time (indefinitely when the target isn't running), so it runs off the
    /// main thread and only for apps that are running (Spotify, Mail).
    private func refreshAutomationStatus() {
        for bundleID in [SpotifyService.bundleID, MailService.bundleID]
        where !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            Task.detached(priority: .utility) { [weak self] in
                let status = Self.automationStatus(bundleID: bundleID)
                await MainActor.run { [weak self] in
                    if bundleID == MailService.bundleID { self?.mailAutomation = status } else { self?.spotifyAutomation = status }
                }
            }
        }
    }

    func requestMicrophone() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
        return granted
    }

    func requestReminders(using service: ReminderService) async {
        _ = try? await service.ensureAccess()
        refresh()
    }

    /// Input Monitoring lets IVY see ⌘⌥ globally with an event tap. Without it IVY falls
    /// back to polling the modifier state, which needs no permission.
    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        refresh()
    }

    func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Checks Apple Events permission without prompting.
    nonisolated static func automationStatus(bundleID: String) -> Status {
        var address = AEAddressDesc()
        let status: OSStatus = bundleID.withCString { pointer in
            let created = AECreateDesc(DescType(typeApplicationBundleID), pointer, bundleID.utf8.count, &address)
            guard created == noErr else { return OSStatus(created) }
            defer { AEDisposeDesc(&address) }
            return AEDeterminePermissionToAutomateTarget(&address, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        }
        switch Int(status) {
        case Int(noErr): return .granted
        case -1743: return .denied            // errAEEventNotPermitted
        case -1744: return .notDetermined     // errAEEventWouldRequireUserConsent
        default: return .notDetermined        // e.g. Spotify not running
        }
    }
}
