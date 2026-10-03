import Foundation

public enum DashboardWidget: String, CaseIterable, Identifiable, Sendable {
    case reminders, event, mail, focus, battery
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .reminders: return "Reminders"
        case .event: return "Calendar"
        case .mail: return "Unread email"
        case .focus: return "Focus"
        case .battery: return "Battery & temperature"
        }
    }
    public var symbol: String {
        switch self {
        case .reminders: return "checklist"
        case .event: return "calendar"
        case .mail: return "envelope"
        case .focus: return "moon"
        case .battery: return "battery.50percent"
        }
    }
}

public extension SettingsStore {
    /// An ordered subset; unknown or duplicate persisted IDs are discarded.
    var dashboardWidgets: [DashboardWidget] {
        var seen = Set<DashboardWidget>()
        return string(.dashboardWidgets).split(separator: ",").compactMap {
            guard let widget = DashboardWidget(rawValue: String($0)), seen.insert(widget).inserted else { return nil }
            return widget
        }
    }
}

/// Numeric release versions only. Prerelease labels cannot silently become an update.
public struct ReleaseVersion: Comparable, Sendable, Equatable {
    public let components: [Int]
    public init?(_ text: String) {
        let text = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              pieces.allSatisfy({ Int($0) != nil }) else { return nil }
        var values = pieces.map { Int($0)! }
        while values.count < 4 { values.append(0) }
        components = values
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}
