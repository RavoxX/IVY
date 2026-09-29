import AppKit
import Combine
import IOKit
import IOKit.ps
import IVYCore
import os

/// Battery health, charge and thermal state. Event-driven: IOKit power-source
/// notifications and ProcessInfo thermal/Low Power Mode changes; no polling.
///
/// The derived `EnergyAdvisor.ModelPolicy` is handed to `AppEnvironment`, which unloads idle
/// models sooner (or right away) when the Mac is hot, in Low Power Mode or low on battery.
@MainActor
final class EnergyMonitor: ObservableObject {
    @Published private(set) var snapshot = EnergySnapshot()
    @Published private(set) var policy: EnergyAdvisor.ModelPolicy = .normal

    var onPolicyChange: ((EnergyAdvisor.ModelPolicy) -> Void)?
    private var runLoopSource: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<EnergyMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
    }

    func refresh() {
        let next = Self.read()
        guard next != snapshot else { return }
        snapshot = next
        let newPolicy = EnergyAdvisor.policy(for: next)
        if newPolicy != policy {
            policy = newPolicy
            Log.engine.info("Energy policy: \(newPolicy.description, privacy: .public)")
            onPolicyChange?(newPolicy)
        }
    }

    static func read() -> EnergySnapshot {
        var snapshot = EnergySnapshot(thermal: thermalLevel(ProcessInfo.processInfo.thermalState),
                                      lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        if let battery = BatteryMonitor.read() {
            snapshot.percent = battery.percent
            snapshot.isCharging = battery.isCharging
            snapshot.isPluggedIn = battery.isPluggedIn
        }
        guard snapshot.hasBattery else { return snapshot }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return snapshot }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return snapshot }
        let nested = properties["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { (properties[key] ?? nested[key]) as? Int }

        snapshot.cycleCount = int("CycleCount")
        // System Settings' "Maximum Capacity" uses the nominal (not raw) full charge.
        if let design = int("DesignCapacity"), design > 0,
           let full = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity") {
            snapshot.healthPercent = min(100, Int((Double(full) / Double(design) * 100).rounded()))
        }
        if let temperature = int("Temperature") ?? int("VirtualTemperature"), temperature > 0 {
            snapshot.temperatureCelsius = Double(temperature) / 100
        }
        if let remaining = int("TimeRemaining") ?? int("AvgTimeToEmpty"), remaining > 0, remaining < 6000, !snapshot.isPluggedIn {
            snapshot.minutesRemaining = remaining
        }
        return snapshot
    }

    private static func thermalLevel(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}

/// Shared idle-timeout cap for the model engines, set from the energy policy.
final class EnergyGovernor: @unchecked Sendable {
    private let lock = NSLock()
    private var capMinutes: Int?

    func setCap(minutes: Int?) {
        lock.withLock { capMinutes = minutes }
    }

    /// The user's idle timeout (0 = never), shortened by the current cap.
    func idleTimeout(userMinutes: Int) -> TimeInterval? {
        let cap = lock.withLock { capMinutes }
        let minutes: Int
        switch (userMinutes > 0 ? userMinutes : nil, cap) {
        case (let user?, let cap?): minutes = min(user, cap)
        case (let user?, nil): minutes = user
        case (nil, let cap?): minutes = cap
        case (nil, nil): return nil
        }
        return TimeInterval(minutes * 60)
    }
}
