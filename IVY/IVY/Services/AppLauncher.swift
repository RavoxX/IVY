import AppKit
import IVYCore

/// Resolves spoken application names ("VS Code", "Chrome", "Safari") to installed apps
/// and launches them with NSWorkspace.
final class AppLauncher: @unchecked Sendable {
    private let lock = NSLock()
    private var index: [String: URL] = [:]
    private var indexedAt: Date = .distantPast

    static let aliases: [String: String] = [
        "vs code": "visual studio code", "vscode": "visual studio code", "code": "visual studio code",
        "chrome": "google chrome", "settings": "system settings", "system preferences": "system settings",
        "preferences": "system settings", "word": "microsoft word", "excel": "microsoft excel",
        "powerpoint": "microsoft powerpoint", "outlook": "microsoft outlook", "teams": "microsoft teams",
        "iterm": "iterm", "iterm2": "iterm", "appstore": "app store", "facetime": "facetime",
        "activity": "activity monitor", "task manager": "activity monitor", "files": "finder",
        "calculator app": "calculator", "photoshop": "adobe photoshop", "whatsapp": "whatsapp",
    ]

    private static let searchFolders: [String] = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications", "/System/Library/CoreServices/Applications",
    ]

    /// Builds (or refreshes, at most every 60 s) the name → URL index.
    private func ensureIndex() {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(indexedAt) > 60 || index.isEmpty else { return }
        var result: [String: URL] = ["finder": URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]
        let fm = FileManager.default
        for folder in Self.searchFolders {
            guard let names = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where name.hasSuffix(".app") {
                let key = String(name.dropLast(4)).lowercased()
                if result[key] == nil { result[key] = URL(fileURLWithPath: folder).appendingPathComponent(name) }
            }
        }
        index = result
        indexedAt = Date()
    }

    func resolve(_ spokenName: String) -> (name: String, url: URL)? {
        ensureIndex()
        var key = spokenName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        key = key.replacingOccurrences(of: #"\s+(app|application)$"#, with: "", options: .regularExpression)
        key = Self.aliases[key] ?? key
        guard !key.isEmpty else { return nil }

        lock.lock(); let snapshot = index; lock.unlock()
        if let url = snapshot[key] { return (displayName(url), url) }
        let compact = key.replacingOccurrences(of: " ", with: "")
        if let match = snapshot.first(where: { $0.key.replacingOccurrences(of: " ", with: "") == compact }) {
            return (displayName(match.value), match.value)
        }
        let prefixed = snapshot.filter { $0.key.hasPrefix(key) }
        if prefixed.count == 1, let match = prefixed.first { return (displayName(match.value), match.value) }
        if key.count >= 4 {
            let containing = snapshot.filter { $0.key.contains(key) }.sorted { $0.key.count < $1.key.count }
            if let match = containing.first { return (displayName(match.value), match.value) }
        }
        return nil
    }

    func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    @discardableResult
    func open(_ url: URL, activate: Bool = true) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        return try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
