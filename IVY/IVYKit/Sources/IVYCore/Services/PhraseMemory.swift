import Foundation

/// Learns what a phrasing meant after a correction: when a request fails and the user
/// rephrases it within a minute, the tool call that finally worked is remembered for the
/// original words. Next time those exact words run that tool directly.
///
/// Only exact (normalized) phrases are matched, nothing high-risk or time-dependent is
/// learned, and the list is visible and editable in Settings.
public final class PhraseMemory: @unchecked Sendable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var phrase: String
        public var toolName: String
        public var arguments: [String: JSONValue]
        public var learnedAt: Date
        public var id: String { phrase }

        public var call: ToolCall { ToolCall(name: toolName, arguments: arguments) }
    }

    /// Tools whose arguments depend on the moment (dates, durations) or that need confirmation.
    public static let neverLearned: Set<String> = [
        ToolName.remindersCreate, ToolName.calendarCreate, ToolName.timerSet, ToolName.moveToTrash,
        ToolName.runCommand, ToolName.startCodingSession, ToolName.remindersComplete,
    ]

    private let fileURL: URL?
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var pendingFailure: (phrase: String, at: Date, explicit: Bool)?
    public var correctionWindow: TimeInterval = 60
    public var maxEntries = 200

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Dictionary(stored.map { ($0.phrase, $0) }, uniquingKeysWith: { $1 })
        }
    }

    public var all: [Entry] {
        lock.withLock { entries.values.sorted { $0.learnedAt > $1.learnedAt } }
    }

    public func lookup(_ query: String) -> ToolCall? {
        let phrase = CommandRouter.normalize(query)
        return lock.withLock { entries[phrase]?.call }
    }

    public enum Outcome: Sendable {
        /// The request failed (error, "I can't do that", cancelled).
        case failed
        /// Answered with text only, which may have missed what the user wanted.
        case plainAnswer
        /// A tool ran successfully.
        case tool(ToolCall)
    }

    /// Feed every finished request.
    public func record(query: String, outcome: Outcome, now: Date = Date()) {
        let phrase = CommandRouter.normalize(query)
        guard !phrase.isEmpty else { return }
        var changed = false
        lock.withLock {
            if case .tool(let call) = outcome, !Self.neverLearned.contains(call.name),
               let pending = pendingFailure, pending.phrase != phrase,
               now.timeIntervalSince(pending.at) <= correctionWindow,
               pending.explicit || Self.sharesContentWord(pending.phrase, phrase) {
                entries[pending.phrase] = Entry(phrase: pending.phrase, toolName: call.name,
                                                arguments: call.arguments, learnedAt: now)
                if entries.count > maxEntries,
                   let oldest = entries.values.min(by: { $0.learnedAt < $1.learnedAt }) {
                    entries.removeValue(forKey: oldest.phrase)
                }
                changed = true
            }
            switch outcome {
            case .failed: pendingFailure = (phrase, now, true)
            case .plainAnswer: pendingFailure = (phrase, now, false)
            case .tool: pendingFailure = nil
            }
        }
        if changed { save() }
    }

    /// A plain answer only counts as a miss when the rephrase is clearly about the same thing.
    static func sharesContentWord(_ first: String, _ second: String) -> Bool {
        let stop: Set<String> = ["what", "what's", "when", "where", "which", "with", "that", "this", "please",
                                 "could", "would", "about", "from", "have", "turn", "make", "want"]
        func words(_ text: String) -> Set<String> {
            Set(text.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
                .filter { $0.count >= 4 && !stop.contains($0) })
        }
        return !words(first).isDisjoint(with: words(second))
    }

    public func forget(_ phrase: String) {
        lock.withLock { _ = entries.removeValue(forKey: phrase) }
        save()
    }

    public func clear() {
        lock.withLock { entries.removeAll() }
        save()
    }

    private func save() {
        guard let fileURL else { return }
        let snapshot = all
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
