import os
import AppKit
import Combine
import IOKit.ps
import IVYCore
import ServiceManagement

/// Battery level for the notch dashboard header (IOKit power sources).
@MainActor
final class BatteryMonitor: ObservableObject {
    struct Reading: Equatable {
        var percent: Int
        var isCharging: Bool
        var isPluggedIn: Bool
    }

    @Published private(set) var reading: Reading?
    private var timer: Timer?

    func refresh() {
        reading = Self.read()
    }

    /// Refresh every 30 s while the dashboard is visible.
    func setVisible(_ visible: Bool) {
        timer?.invalidate()
        timer = nil
        guard visible else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    static func read() -> Reading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return Reading(percent: max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current,
                           isCharging: charging, isPluggedIn: plugged)
        }
        return nil
    }
}

/// Files dropped on the notch shelf (references only; files are never copied or moved).
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [URL] = []
    private let key = "shelf.items"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let paths = defaults.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL && !items.contains(url) {
            items.append(url)
        }
        if items.count > 24 { items.removeFirst(items.count - 24) }
        persist()
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(items.map(\.path), forKey: key)
    }

    /// Sends files with AirDrop via the system sharing service.
    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        if service.canPerform(withItems: urls) {
            service.perform(withItems: urls)
        }
    }
}

/// Launch at login via SMAppService (macOS 13+).
enum LoginItemService {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.ui.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
