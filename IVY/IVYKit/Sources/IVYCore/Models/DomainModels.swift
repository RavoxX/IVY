import Foundation

// MARK: - Music

public enum PlaybackStatus: String, Codable, Sendable, Equatable {
    case playing, paused, stopped, unavailable

    public var displayName: String {
        switch self {
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .unavailable: return "Not running"
        }
    }
}

/// Snapshot of the Spotify player, read from the running desktop app.
public struct MusicState: Codable, Sendable, Equatable {
    public var player: String
    public var status: PlaybackStatus
    public var title: String
    public var artist: String
    public var album: String
    public var artworkURL: URL?
    public var trackID: String?
    public var duration: TimeInterval
    public var position: TimeInterval
    public var shuffling: Bool
    public var repeating: Bool
    public var volume: Int
    /// When the snapshot was taken; used to interpolate the progress bar.
    public var capturedAt: Date

    public init(player: String = "Spotify", status: PlaybackStatus, title: String = "", artist: String = "",
                album: String = "", artworkURL: URL? = nil, trackID: String? = nil, duration: TimeInterval = 0,
                position: TimeInterval = 0, shuffling: Bool = false, repeating: Bool = false, volume: Int = 50,
                capturedAt: Date = Date()) {
        self.player = player
        self.status = status
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.trackID = trackID
        self.duration = duration
        self.position = position
        self.shuffling = shuffling
        self.repeating = repeating
        self.volume = volume
        self.capturedAt = capturedAt
    }

    public var hasTrack: Bool { !title.isEmpty }

    /// Position extrapolated to `date` while playing.
    public func position(at date: Date) -> TimeInterval {
        guard status == .playing else { return position }
        return min(duration, position + max(0, date.timeIntervalSince(capturedAt)))
    }
}

// MARK: - Reminders

public struct ReminderItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var dueDate: Date?
    /// True when the due date has a time component (vs. an all-day reminder).
    public var hasDueTime: Bool
    public var isCompleted: Bool
    public var listName: String
    public var notes: String?
    public var priority: Int

    public init(id: String, title: String, dueDate: Date?, hasDueTime: Bool, isCompleted: Bool = false,
                listName: String = "Reminders", notes: String? = nil, priority: Int = 0) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.hasDueTime = hasDueTime
        self.isCompleted = isCompleted
        self.listName = listName
        self.notes = notes
        self.priority = priority
    }
}

// MARK: - Coding sessions

public struct CodingSessionInfo: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case terminal, background }
    public enum Status: String, Codable, Sendable { case running, finished, failed }

    public var id: UUID
    public var agent: String
    public var projectName: String
    public var directory: URL
    public var task: String
    public var mode: Mode
    public var status: Status
    public var startedAt: Date
    public var detail: String?

    public init(id: UUID = UUID(), agent: String, projectName: String, directory: URL, task: String, mode: Mode,
                status: Status, startedAt: Date = Date(), detail: String? = nil) {
        self.id = id
        self.agent = agent
        self.projectName = projectName
        self.directory = directory
        self.task = task
        self.mode = mode
        self.status = status
        self.startedAt = startedAt
        self.detail = detail
    }
}

// MARK: - Web, timers, weather, calendar

public struct SourceLink: Codable, Sendable, Equatable, Identifiable {
    public var title: String
    public var url: URL
    public var snippet: String
    public var id: URL { url }

    public init(title: String, url: URL, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public struct TimerInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var label: String?
    public var endDate: Date
    public var duration: TimeInterval
    public var isAlarm: Bool

    public init(id: UUID = UUID(), label: String?, endDate: Date, duration: TimeInterval, isAlarm: Bool) {
        self.id = id
        self.label = label
        self.endDate = endDate
        self.duration = duration
        self.isAlarm = isAlarm
    }

    public func remaining(at date: Date = Date()) -> TimeInterval { max(0, endDate.timeIntervalSince(date)) }
    public var title: String { label.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? (isAlarm ? "Alarm" : "Timer") }
}

public struct WeatherReport: Codable, Sendable, Equatable {
    public var location: String
    public var day: String
    public var temperature: Double
    public var apparent: Double?
    public var high: Double
    public var low: Double
    public var condition: String
    public var symbol: String
    public var precipitationChance: Int?
    public var unit: String

    public init(location: String, day: String, temperature: Double, apparent: Double?, high: Double, low: Double,
                condition: String, symbol: String, precipitationChance: Int?, unit: String) {
        self.location = location
        self.day = day
        self.temperature = temperature
        self.apparent = apparent
        self.high = high
        self.low = low
        self.condition = condition
        self.symbol = symbol
        self.precipitationChance = precipitationChance
        self.unit = unit
    }
}

public struct CalendarEventItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendar: String
    public var location: String?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool, calendar: String, location: String?) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendar = calendar
        self.location = location
    }
}

// MARK: - Result cards

/// Structured UI content attached to a tool result. The notch renders these as cards
/// rather than chat bubbles.
public enum ResultCard: Sendable, Equatable {
    case reminders(title: String, items: [ReminderItem])
    case music(MusicState)
    case appLaunched(name: String, bundlePath: String?)
    case link(title: String, url: URL)
    case file(url: URL)
    case codingSession(CodingSessionInfo)
    case list(title: String, rows: [String])
    case settings(section: String?)
    case sources(query: String, items: [SourceLink])
    case timers([TimerInfo])
    case weather(WeatherReport)
    case events(title: String, items: [CalendarEventItem])
    case files(title: String, items: [FileHit])
    /// Longer generated text (clipboard results) with a Copy button.
    case text(title: String, body: String)
    case definition(DefinitionResult)
    case mail(title: String, items: [MailMessageItem])
    case energy(EnergySnapshot)
}
