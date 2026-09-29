import Foundation

/// Turns battery and thermal readings into advice and a model-loading policy.
///
/// Local models are the biggest power draw IVY has. When the Mac runs hot, is in Low Power
/// Mode or is low on battery, IVY unloads idle models sooner (or right away when critical).
public enum EnergyAdvisor {
    public enum ModelPolicy: Equatable, Sendable {
        case normal
        /// Unload idle models after this many minutes (overrides a longer user setting).
        case conserve(idleMinutes: Int)
        /// Unload idle models now.
        case unloadNow

        public var description: String {
            switch self {
            case .normal: return "Models stay loaded as configured."
            case .conserve(let minutes): return "Idle models unload after \(minutes) min to save energy."
            case .unloadNow: return "Idle models are unloaded to cool down."
            }
        }
    }

    public static func policy(for snapshot: EnergySnapshot) -> ModelPolicy {
        if snapshot.thermal == .critical { return .unloadNow }
        if snapshot.onBattery, let percent = snapshot.percent, percent <= 10 { return .unloadNow }
        if snapshot.thermal == .serious { return .conserve(idleMinutes: 2) }
        if snapshot.lowPowerMode { return .conserve(idleMinutes: 3) }
        if snapshot.onBattery, let percent = snapshot.percent, percent <= 25 { return .conserve(idleMinutes: 3) }
        return .normal
    }

    public static func healthLabel(_ percent: Int) -> String {
        percent >= 80 ? "Normal" : "Service recommended"
    }

    /// Short, actionable suggestions, most important first.
    public static func advice(for snapshot: EnergySnapshot) -> [String] {
        var tips: [String] = []
        switch snapshot.thermal {
        case .critical: tips.append("Your Mac is very hot. IVY unloaded its models to help it cool down.")
        case .serious: tips.append("Your Mac is running hot, so IVY unloads idle models sooner.")
        default: break
        }
        if let percent = snapshot.percent {
            if snapshot.onBattery {
                let left = snapshot.minutesRemaining.map { " (about \(durationText($0)) left)" } ?? ""
                if percent <= 20 {
                    tips.append("Charge soon\(left).")
                } else if percent <= 40 {
                    tips.append("Plan to charge within the next few hours\(left).")
                } else {
                    tips.append("No need to charge yet\(left).")
                }
            } else if percent >= 95 && !snapshot.isCharging {
                tips.append("Fully charged. You can unplug; keeping it at 100% all day ages the battery faster.")
            } else if snapshot.isCharging {
                tips.append("Charging.")
            }
        }
        if let health = snapshot.healthPercent, health < 80 {
            tips.append("Battery health is \(health)%. Consider having it checked.")
        }
        if let temperature = snapshot.temperatureCelsius, temperature >= 40 {
            tips.append("The battery is warm (\(Int(temperature.rounded())) °C). Avoid charging under heavy load.")
        }
        if snapshot.lowPowerMode { tips.append("Low Power Mode is on.") }
        return tips
    }

    /// One or two sentences for the notch answer.
    public static func summary(for snapshot: EnergySnapshot) -> String {
        guard let percent = snapshot.percent else {
            return "This Mac has no battery. Thermal state: \(snapshot.thermal.displayName.lowercased())."
        }
        var parts = ["Battery at \(percent)%"]
        if let health = snapshot.healthPercent { parts.append("health \(health)%") }
        if let cycles = snapshot.cycleCount { parts.append("\(cycles) cycles") }
        var text = parts.joined(separator: ", ") + "."
        if let first = advice(for: snapshot).first { text += " " + first }
        return text
    }

    public static func durationText(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    // MARK: - Natural language

    /// "how's my battery health", "should I charge", "is my mac overheating".
    public static func matches(_ normalized: String) -> Bool {
        let patterns = [
            #"\bbattery (health|condition|cycles?|cycle count|capacity|status)\b"#,
            #"^how('s| is) (my |the )?battery( doing| holding up)?$"#,
            #"\b(should|when should|do) i (charge|plug in|unplug)\b"#,
            #"\bcycle count\b"#,
            #"\b(overheating|too hot|thermal|running hot|getting hot)\b"#,
            #"^is (my |the )?mac (hot|warm)$"#,
            #"\benergy (status|usage|report)\b"#,
        ]
        return patterns.contains { normalized.range(of: $0, options: .regularExpression) != nil }
    }
}
