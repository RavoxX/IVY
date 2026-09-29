import Foundation

public struct HistoryEntry: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable { case success, failure, cancelled, running }

    public var id: UUID
    public var timestamp: Date
    public var query: String
    public var title: String
    public var toolName: String?
    public var result: String
    public var status: Status

    public init(id: UUID = UUID(), timestamp: Date = Date(), query: String, title: String, toolName: String?,
                result: String, status: Status) {
        self.id = id
        self.timestamp = timestamp
        self.query = query
        self.title = title
        self.toolName = toolName
        self.result = result
        self.status = status
    }
}

/// Small, local-only interaction history stored as JSON in Application Support.
/// Audio is never stored here.
public actor HistoryStore {
    public let fileURL: URL
    public let limit: Int
    private var entries: [HistoryEntry] = []
    private var loaded = false

    public init(fileURL: URL, limit: Int = 50) {
        self.fileURL = fileURL
        self.limit = limit
    }

    public func all() -> [HistoryEntry] {
        loadIfNeeded()
        return entries
    }

    @discardableResult
    public func append(_ entry: HistoryEntry) -> [HistoryEntry] {
        loadIfNeeded()
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        persist()
        return entries
    }

    @discardableResult
    public func update(id: UUID, _ transform: @Sendable (inout HistoryEntry) -> Void) -> [HistoryEntry] {
        loadIfNeeded()
        if let index = entries.firstIndex(where: { $0.id == id }) {
            transform(&entries[index])
            persist()
        }
        return entries
    }

    public func clear() {
        entries = []
        loaded = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }

    /// Derives a short history title such as "Daily Reminder Overview" or "Spotify Music Playback".
    public static func title(forTool tool: String?, query: String) -> String {
        switch tool {
        case ToolName.remindersList?: return "Daily Reminder Overview"
        case ToolName.remindersCreate?: return "New Reminder"
        case ToolName.remindersComplete?: return "Completed Reminder"
        case ToolName.remindersSearch?: return "Reminder Search"
        case ToolName.musicPlay?, ToolName.musicControl?, ToolName.musicNowPlaying?, ToolName.musicVolume?:
            return "Spotify Music Playback"
        case ToolName.openApp?: return "Open Application"
        case ToolName.openURL?: return "Open Website"
        case ToolName.openFile?, ToolName.revealInFinder?: return "Open in Finder"
        case ToolName.openSettings?: return "IVY Settings"
        case ToolName.startCodingSession?: return "Coding Session"
        case ToolName.moveToTrash?: return "Move to Trash"
        case ToolName.runCommand?: return "Run Command"
        case ToolName.browserSearch?: return "Browser Search"
        case ToolName.webSearch?: return "Web Search"
        case ToolName.timerSet?, ToolName.timerList?, ToolName.timerCancel?: return "Timer"
        case ToolName.weather?: return "Weather"
        case ToolName.calendarEvents?: return "Calendar"
        case ToolName.systemVolume?, ToolName.darkMode?, ToolName.systemInfo?: return "System"
        case ToolName.calculate?: return "Calculation"
        case ToolName.fileSearch?: return "File Search"
        case ToolName.clipboard?: return "Clipboard"
        case ToolName.dictionary?: return "Dictionary"
        case ToolName.mailSearch?: return "Mail"
        case ToolName.calendarCreate?: return "New Event"
        case ToolName.shortcutRun?: return "Shortcut"
        case ToolName.focus?: return "Focus"
        case ToolName.energyStatus?: return "Battery & Energy"
        case ToolName.lowPowerMode?: return "Low Power Mode"
        default:
            let words = query.split(separator: " ").prefix(5).joined(separator: " ")
            return words.isEmpty ? "Question" : words
        }
    }
}
