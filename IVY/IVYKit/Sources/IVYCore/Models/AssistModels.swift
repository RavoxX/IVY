import Foundation

// MARK: - Files

/// One Spotlight result.
public struct FileHit: Codable, Sendable, Equatable, Identifiable {
    public var url: URL
    public var modified: Date?
    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(url: URL, modified: Date?) {
        self.url = url
        self.modified = modified
    }
}

// MARK: - Dictionary

public struct DefinitionResult: Codable, Sendable, Equatable {
    public var word: String
    public var definition: String?
    public var synonyms: [String]
    public var antonyms: [String]
    /// True when the definition came from the macOS dictionary (vs. the local model).
    public var fromSystemDictionary: Bool

    public init(word: String, definition: String?, synonyms: [String] = [], antonyms: [String] = [],
                fromSystemDictionary: Bool = true) {
        self.word = word
        self.definition = definition
        self.synonyms = synonyms
        self.antonyms = antonyms
        self.fromSystemDictionary = fromSystemDictionary
    }
}

// MARK: - Mail

/// Envelope data of one inbox message (IVY never reads message bodies).
public struct MailMessageItem: Codable, Sendable, Equatable, Identifiable {
    /// RFC 822 Message-ID, used to open the message in Mail.
    public var id: String
    public var sender: String
    public var subject: String
    public var date: Date
    public var isRead: Bool

    public init(id: String, sender: String, subject: String, date: Date, isRead: Bool) {
        self.id = id
        self.sender = sender
        self.subject = subject
        self.date = date
        self.isRead = isRead
    }

    /// "Alex Kim <alex@example.com>" → "Alex Kim".
    public var senderName: String { MailFilter.senderName(sender) }
}

// MARK: - Shortcuts

public struct ShortcutInfo: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var id: String

    public init(name: String, id: String) {
        self.name = name
        self.id = id
    }
}

// MARK: - Energy

public enum ThermalLevel: String, Codable, Sendable, CaseIterable {
    case nominal, fair, serious, critical

    public var displayName: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Very hot"
        }
    }
}

/// Battery, thermal and model state at one moment.
public struct EnergySnapshot: Codable, Sendable, Equatable {
    public var percent: Int?
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var cycleCount: Int?
    /// Current full-charge capacity relative to the design capacity.
    public var healthPercent: Int?
    public var temperatureCelsius: Double?
    public var minutesRemaining: Int?
    public var thermal: ThermalLevel
    public var lowPowerMode: Bool
    public var modelLoaded: Bool
    public var modelName: String?

    public init(percent: Int? = nil, isCharging: Bool = false, isPluggedIn: Bool = false, cycleCount: Int? = nil,
                healthPercent: Int? = nil, temperatureCelsius: Double? = nil, minutesRemaining: Int? = nil,
                thermal: ThermalLevel = .nominal, lowPowerMode: Bool = false, modelLoaded: Bool = false,
                modelName: String? = nil) {
        self.percent = percent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
        self.temperatureCelsius = temperatureCelsius
        self.minutesRemaining = minutesRemaining
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
        self.modelLoaded = modelLoaded
        self.modelName = modelName
    }

    public var hasBattery: Bool { percent != nil }
    public var onBattery: Bool { hasBattery && !isPluggedIn }
}
