import AppKit
import CoreServices
import IVYCore
import os

/// Spotlight file search through `NSMetadataQuery` (the same index Finder uses).
@MainActor
final class FileSearchService {
    private static let skippedPathParts = ["/Library/", "/.Trash/", "/node_modules/", "/.git/", "/site-packages/", "/DerivedData/"]

    func search(_ request: FileSearchRequest, limit: Int = 20, now: Date = Date()) async -> [FileHit] {
        let query = NSMetadataQuery()
        query.predicate = request.predicate(now: now)
        query.searchScopes = scopes(for: request)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]

        return await withCheckedContinuation { continuation in
            var finished = false
            var observer: NSObjectProtocol?
            let complete = {
                guard !finished else { return }
                finished = true
                query.stop()
                if let observer { NotificationCenter.default.removeObserver(observer) }
                continuation.resume(returning: Self.hits(from: query, limit: limit))
            }
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                              object: query, queue: .main) { _ in
                MainActor.assumeIsolated { complete() }
            }
            // Spotlight answers in well under a second; don't hang if the index is busy.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                MainActor.assumeIsolated { complete() }
            }
            if !query.start() { complete() }
        }
    }

    private func scopes(for request: FileSearchRequest) -> [Any] {
        if let folder = request.folder, let url = FilePathResolver.resolve(folder) { return [url] }
        if request.kind == .app {
            return ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0) }
        }
        return [NSMetadataQueryUserHomeScope]
    }

    private static func hits(from query: NSMetadataQuery, limit: Int) -> [FileHit] {
        var hits: [FileHit] = []
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !skippedPathParts.contains(where: path.contains),
                  !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            let modified = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            hits.append(FileHit(url: URL(fileURLWithPath: path), modified: modified))
            if hits.count >= limit { break }
        }
        return hits
    }
}

/// Plain-text clipboard access. IVY only reads the clipboard when asked and only writes
/// when the user taps Copy or asks it to copy the result.
enum ClipboardService {
    @MainActor static func read() -> String? {
        NSPasteboard.general.string(forType: .string)?.nilIfBlank
    }

    @MainActor static func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Offline definitions from the dictionaries installed with macOS (Dictionary.app).
enum SystemDictionary {
    static func definition(of word: String) -> String? {
        let range = CFRange(location: 0, length: (word as NSString).length)
        guard let raw = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() as String? else { return nil }
        let cleaned = WordLookup.cleanDefinition(raw)
        return cleaned.isEmpty ? nil : cleaned
    }
}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

// MARK: - Mail

/// Reads inbox envelopes (sender, subject, date, read state) from Apple Mail with a fixed
/// AppleScript. Nothing from the request is interpolated into the script; filtering happens
/// in Swift (`MailFilter`). Message bodies are never read.
final class MailService: @unchecked Sendable {
    static let bundleID = "com.apple.mail"
    private let runner = AppleScriptRunner.shared

    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }

    /// Mail is only launched when the user explicitly asks about email.
    func ensureRunning() async throws {
        guard !isRunning else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            throw ToolError.unavailable("Apple Mail isn't installed.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<20 where !isRunning { try await Task.sleep(for: .milliseconds(250)) }
        try await Task.sleep(for: .seconds(1)) // Let Mail finish loading its accounts.
    }

    /// Envelopes of inbox messages received in the last `days` days, newest first.
    ///
    /// Mail can't read a property from a *list* of messages ("Can't get sender of {message id…}"),
    /// so the script asks each account's inbox with one filtered specifier per property, and
    /// falls back to reading messages one by one if an account doesn't support that.
    func recentInbox(days: Int = 14, limit: Int = 150) async throws -> [MailMessageItem] {
        let days = max(1, min(365, days))
        let perBox = max(1, min(400, limit))
        let script = """
        tell application id "\(Self.bundleID)"
            set cutoff to (current date) - (\(days) * days)
            set {allSenders, allSubjects, allDates, allReads, allIDs} to {{}, {}, {}, {}, {}}
            set boxes to every mailbox of inbox
            if (count of boxes) = 0 then set boxes to {inbox}
            repeat with boxRef in boxes
                set box to contents of boxRef
                try
                    set s to sender of (every message of box whose date received > cutoff)
                    set t to subject of (every message of box whose date received > cutoff)
                    set d to date received of (every message of box whose date received > cutoff)
                    set r to read status of (every message of box whose date received > cutoff)
                    set i to message id of (every message of box whose date received > cutoff)
                    set n to count of s
                    if n = (count of t) and n = (count of d) and n = (count of r) and n = (count of i) then
                        set allSenders to allSenders & s
                        set allSubjects to allSubjects & t
                        set allDates to allDates & d
                        set allReads to allReads & r
                        set allIDs to allIDs & i
                    end if
                on error
                    try
                        set found to (every message of box whose date received > cutoff)
                        set n to count of found
                        if n > \(perBox) then set n to \(perBox)
                        repeat with k from 1 to n
                            set m to item k of found
                            set end of allSenders to sender of m
                            set end of allSubjects to subject of m
                            set end of allDates to date received of m
                            set end of allReads to read status of m
                            set end of allIDs to message id of m
                        end repeat
                    end try
                end try
            end repeat
            return {allSenders, allSubjects, allDates, allReads, allIDs}
        end tell
        """
        let result = try await execute(script)
        guard result.numberOfItems == 5,
              let senders = result.atIndex(1), let subjects = result.atIndex(2), let dates = result.atIndex(3),
              let reads = result.atIndex(4), let ids = result.atIndex(5) else { return [] }
        let total = [senders, subjects, dates, reads, ids].map(\.numberOfItems).min() ?? 0
        guard total > 0 else { return [] }
        var items: [MailMessageItem] = []
        for index in 1...total {
            items.append(MailMessageItem(
                id: ids.atIndex(index)?.stringValue ?? UUID().uuidString,
                sender: senders.atIndex(index)?.stringValue ?? "",
                subject: subjects.atIndex(index)?.stringValue ?? "",
                date: dates.atIndex(index)?.dateValue ?? .distantPast,
                isRead: reads.atIndex(index)?.booleanValue ?? true))
        }
        return Array(items.sorted { $0.date > $1.date }.prefix(limit))
    }

    func unreadCount() async throws -> Int {
        Int(try await execute("tell application id \"\(Self.bundleID)\" to return unread count of inbox").int32Value)
    }

    /// `message://%3cID%3e` opens the message in Mail.
    static func url(forMessageID id: String) -> URL? {
        let wrapped = "<\(id)>"
        guard let encoded = wrapped.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "message://\(encoded)")
    }

    private func execute(_ source: String) async throws -> NSAppleEventDescriptor {
        do {
            return try await runner.run(source)
        } catch let error as AppleScriptRunner.ScriptError where error.isPermissionDenied {
            throw ToolError.permissionDenied("Automation (IVY → Mail)")
        } catch let error as AppleScriptRunner.ScriptError {
            // Mail's errors list every message reference; never show that to the user.
            Log.tools.error("Mail script failed (\(error.code)): \(String(error.message.prefix(300)), privacy: .public)")
            throw ToolError.failed("I couldn't read your Mail inbox (error \(error.code)).")
        }
    }
}

// MARK: - Shortcuts

/// Runs the user's own Shortcuts with `/usr/bin/shortcuts`. Only shortcuts that exist are
/// run (by identifier), arguments are passed as an array (no shell), and input is written
/// to a temporary file.
final class ShortcutsService: @unchecked Sendable {
    private static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")
    private let lock = NSLock()
    private var cache: [ShortcutInfo] = []
    private var fetchedAt: Date = .distantPast

    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: Self.executable.path) }

    /// Names known from the last listing (used in the tool description for the model).
    var cachedShortcuts: [ShortcutInfo] { lock.withLock { cache } }

    func list(refresh: Bool = false) async -> [ShortcutInfo] {
        let fresh = lock.withLock { !refresh && Date().timeIntervalSince(fetchedAt) < 120 ? cache : nil }
        if let fresh { return fresh }
        guard isAvailable else { return [] }
        let result = await ProcessRunner.run(executable: Self.executable, arguments: ["list", "--show-identifiers"], timeout: 15)
        let shortcuts = result.stdout.split(separator: "\n").compactMap { line -> ShortcutInfo? in
            guard let match = String(line).firstCapture(#"^(.+) \(([0-9A-Fa-f-]{36})\)$"#) else { return nil }
            return ShortcutInfo(name: match.0, id: match.1)
        }
        lock.withLock {
            cache = shortcuts
            fetchedAt = Date()
        }
        return shortcuts
    }

    enum InstallResult {
        case added(ShortcutInfo)
        /// The Add Shortcut sheet is open but the user hasn't confirmed (yet).
        case waiting
    }

    /// Installs a generated one-action shortcut: macOS signs it (`shortcuts sign`, which asks
    /// Apple's signing service), then Shortcuts shows its "Add Shortcut" sheet. Nothing is
    /// added unless the user confirms there. Waits up to `timeout` for the shortcut to appear.
    func install(name: String, workflow: Data, timeout: TimeInterval = 90) async throws -> InstallResult {
        let fileName = ShortcutBuilder.safeFileName(name)
        let folder = AppPaths.temporary.appendingPathComponent("shortcuts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let unsigned = folder.appendingPathComponent("unsigned.shortcut")
        let signed = folder.appendingPathComponent("\(fileName).shortcut")
        try workflow.write(to: unsigned)
        let result = await ProcessRunner.run(executable: Self.executable,
                                             arguments: ["sign", "--mode", "anyone", "--input", unsigned.path, "--output", signed.path],
                                             timeout: 60)
        guard result.status == 0, FileManager.default.fileExists(atPath: signed.path) else {
            Log.tools.error("Signing shortcut failed: \(result.stderr.prefix(200), privacy: .public)")
            throw ToolError.failed("I couldn't prepare the “\(fileName)” shortcut. macOS needs an internet connection to sign it.")
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(signed) }
        guard opened else { throw ToolError.failed("I couldn't open the Shortcuts app.") }
        Log.tools.info("Offered shortcut for import")

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(1.5))
            if let added = await list(refresh: true).first(where: { $0.name.caseInsensitiveCompare(fileName) == .orderedSame }) {
                try? FileManager.default.removeItem(at: folder)
                return .added(added)
            }
        }
        return .waiting
    }

    /// Runs a shortcut and returns its text output, if any.
    func run(_ shortcut: ShortcutInfo, input: String?) async throws -> String? {
        let folder = AppPaths.temporary.appendingPathComponent("shortcuts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let token = UUID().uuidString
        let output = folder.appendingPathComponent("\(token)-out.txt")
        var arguments = ["run", shortcut.id, "--output-path", output.path, "--output-type", "public.plain-text"]
        var inputFile: URL?
        if let input, !input.isEmpty {
            let file = folder.appendingPathComponent("\(token)-in.txt")
            try input.write(to: file, atomically: true, encoding: .utf8)
            arguments += ["--input-path", file.path]
            inputFile = file
        }
        defer {
            try? FileManager.default.removeItem(at: output)
            if let inputFile { try? FileManager.default.removeItem(at: inputFile) }
        }
        let result = await ProcessRunner.run(executable: Self.executable, arguments: arguments, timeout: 60)
        guard result.status == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.tools.error("Shortcut failed: \(message, privacy: .public)")
            throw ToolError.failed("The shortcut “\(shortcut.name)” failed\(message.isEmpty ? "" : ": \(message.prefix(120))").")
        }
        let text = (try? String(contentsOf: output, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? String(text!.prefix(300)) : nil
    }
}

private extension String {
    func firstCapture(_ pattern: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let first = Range(match.range(at: 1), in: self), let second = Range(match.range(at: 2), in: self) else { return nil }
        return (String(self[first]), String(self[second]))
    }
}

// MARK: - Focus

/// Reads the active Focus from `~/Library/DoNotDisturb/DB` (macOS has no public API for it).
/// That folder is protected, so this needs Full Disk Access; without it IVY says so.
final class FocusService: @unchecked Sendable {
    enum State: Equatable {
        case off
        case on(String)
        case unavailable
    }

    private let lock = NSLock()
    private var cached: (state: State, at: Date)?
    private static var folder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    }

    func current(maxAge: TimeInterval = 15) -> State {
        if let cached = lock.withLock({ cached }), Date().timeIntervalSince(cached.at) < maxAge { return cached.state }
        let state = Self.read()
        lock.withLock { cached = (state, Date()) }
        return state
    }

    func invalidate() {
        lock.withLock { cached = nil }
    }

    /// Standard Focus names in the system language ("Do Not Disturb" → "Nicht stören"), read
    /// from macOS's own DoNotDisturb strings. Shortcuts' Set Focus action matches modes by
    /// this localized name.
    static let localizedModeNames: [String: String] = {
        let keys = ["DEFAULT": "Do Not Disturb", "SLEEP": "Sleep", "WORK": "Work", "PERSONAL": "Personal",
                    "DRIVING": "Driving", "FITNESS": "Fitness", "GAMING": "Gaming", "MINDFULNESS": "Mindfulness",
                    "READING": "Reading", "REDUCE_INTERRUPTIONS": "Reduce Interruptions"]
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/DoNotDisturb.framework/Versions/A/Resources/Localizable.loctable")
        guard let data = try? Data(contentsOf: url),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        let languages = table.keys.filter { $0 != "LocProvenance" }
        let language = Bundle.preferredLocalizations(from: languages, forPreferences: Locale.preferredLanguages).first ?? "en"
        guard let strings = table[language] as? [String: String] else { return [:] }
        var names: [String: String] = [:]
        for (key, english) in keys {
            if let name = strings["MODE_NAME_\(key)"] { names[english] = name }
        }
        return names
    }()

    /// Identifier → name of the user's Focus modes (needs Full Disk Access).
    func modeIdentifiers() -> [String: String] {
        let url = Self.folder.appendingPathComponent("ModeConfigurations.json")
        return (try? Data(contentsOf: url)).map(FocusParser.modeNames(configurations:)) ?? [:]
    }

    /// The user's Focus names (needs Full Disk Access), else Apple's standard ones.
    func modeNames() -> [String] {
        let url = Self.folder.appendingPathComponent("ModeConfigurations.json")
        let names = (try? Data(contentsOf: url)).map(FocusParser.modeNames(configurations:))?.values.sorted() ?? []
        return names.isEmpty ? FocusParser.standardModes.map { Self.localizedModeNames[$0] ?? $0 } : names
    }

    var activeName: String? {
        if case .on(let name) = current() { return name }
        return nil
    }

    private static func read() -> State {
        guard let assertions = try? Data(contentsOf: folder.appendingPathComponent("Assertions.json")) else {
            return .unavailable
        }
        guard let identifier = FocusParser.activeModeIdentifier(assertions: assertions) else { return .off }
        let names = (try? Data(contentsOf: folder.appendingPathComponent("ModeConfigurations.json")))
            .map(FocusParser.modeNames(configurations:)) ?? [:]
        return .on(FocusParser.displayName(for: identifier, names: names))
    }
}
