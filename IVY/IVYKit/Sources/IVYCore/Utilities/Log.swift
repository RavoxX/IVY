import Foundation
import os

/// Structured logging categories. View with:
/// `log stream --predicate 'subsystem == "com.ravoxx.IVY"' --level debug`
///
/// Privacy: user prompts and transcripts are logged only as `.private` (redacted in
/// release logs) and microphone audio is never logged.
public enum Log {
    public static let subsystem = "com.ravoxx.IVY"

    public static let ui = Logger(subsystem: subsystem, category: "UI")
    public static let input = Logger(subsystem: subsystem, category: "Input")
    public static let speech = Logger(subsystem: subsystem, category: "Speech")
    public static let llm = Logger(subsystem: subsystem, category: "LLM")
    public static let tts = Logger(subsystem: subsystem, category: "TTS")
    public static let agent = Logger(subsystem: subsystem, category: "Agent")
    public static let tools = Logger(subsystem: subsystem, category: "Tools")
    public static let spotify = Logger(subsystem: subsystem, category: "Spotify")
    public static let reminders = Logger(subsystem: subsystem, category: "Reminders")
    public static let claudeCode = Logger(subsystem: subsystem, category: "ClaudeCode")
    public static let engine = Logger(subsystem: subsystem, category: "Engine")
}
