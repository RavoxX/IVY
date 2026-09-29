import Foundation

/// Suggests the tools a request probably needs ("any new mail?" → `mail_search`).
///
/// All tool schemas stay in the prompt: they're prefilled once and cached, so sending a
/// different subset per request would make every request re-read ~1–2k tokens. Instead the
/// hint goes into the (uncached) request line, which steers a small model toward the right
/// tool at no speed cost.
public enum ToolHints {
    static let groups: [(pattern: String, tools: [String])] = [
        (#"\b(e-?mails?|mails?|inbox|posteingang)\b"#, [ToolName.mailSearch]),
        (#"\b(calendar|kalender|meetings?|events?|appointments?|termine?)\b"#, [ToolName.calendarEvents, ToolName.calendarCreate]),
        (#"\b(remind|reminders?|to-?dos?|tasks?|erinner\w*)\b"#, [ToolName.remindersList, ToolName.remindersCreate, ToolName.remindersComplete]),
        (#"\b(play|song|music|spotify|track|album|playlist|pause|skip|musik)\b"#, [ToolName.musicPlay, ToolName.musicControl]),
        (#"\b(files?|pdfs?|documents?|folders?|downloads|spreadsheets?|dateien?)\b"#, [ToolName.fileSearch, ToolName.openFile]),
        (#"\b(clipboard|copied|zwischenablage)\b"#, [ToolName.clipboard]),
        (#"\b(define|definition|meaning|mean|synonyms?|antonyms?|opposite|another word)\b"#, [ToolName.dictionary]),
        (#"\b(focus|fokus|do not disturb|nicht stören|dnd)\b"#, [ToolName.focus]),
        (#"\b(low power|energy saving|stromspar\w*|battery saver)\b"#, [ToolName.lowPowerMode]),
        (#"\b(battery|akku|charge|charging|overheating|thermal|too hot)\b"#, [ToolName.energyStatus]),
        (#"\b(lights?|lamps?|lampen?|licht|thermostat|heating|heizung|scene|shortcuts?|kurzbefehl\w*)\b"#, [ToolName.shortcutRun]),
        (#"\b(timers?|alarms?|wecker|wake me)\b"#, [ToolName.timerSet, ToolName.timerList]),
        (#"\b(weather|forecast|rain|wetter)\b"#, [ToolName.weather]),
        (#"\b(search|look up|google|news|latest|who is|who won|price of|wer ist)\b"#, [ToolName.webSearch, ToolName.browserSearch]),
        (#"\b(claude|codex)\b"#, [ToolName.startCodingSession]),
        (#"\b(volume|mute|lautstärke|dark mode|light mode)\b"#, [ToolName.systemVolume, ToolName.darkMode]),
    ]

    public static func relevant(for query: String) -> [String] {
        let text = query.lowercased()
        var tools: [String] = []
        for group in groups where text.range(of: group.pattern, options: .regularExpression) != nil {
            for tool in group.tools where !tools.contains(tool) { tools.append(tool) }
        }
        return Array(tools.prefix(6))
    }
}
