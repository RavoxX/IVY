import AppKit
import IVYCore

struct CloseApplicationTool: IVYTool {
    let name = ToolName.closeApp
    let description = "Force quit a named running application on this Mac. Unsaved changes may be lost; requires confirmation. Does not close individual windows or tabs."
    let displayName = "Force Quit App"
    let baseRisk = RiskLevel.high
    var parameters: [ToolParameter] {
        [ToolParameter("name", .string, "Application name, e.g. 'Epic Games Launcher' or 'Safari'.", required: true)]
    }

    func confirmationPrompt(for arguments: [String: JSONValue]) -> String {
        "Force quit “\(arguments.string("name") ?? "this application")”? Unsaved changes may be lost."
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let requested = try arguments.requiredString("name")
        guard requested.count <= 200, requested.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ToolError.invalidArgument("name", "use an application name")
        }
        return try await forceQuit(requested)
    }

    /// NSRunningApplication targets the actual app instances, without shell commands,
    /// process-name matching or killing unrelated helpers. A request alone isn't success.
    @MainActor
    private func forceQuit(_ requested: String) async throws -> ToolResult {
        let key = Self.normalized(requested)
        guard !key.isEmpty else { throw ToolError.invalidArgument("name", "use an application name") }
        let running = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy != .prohibited && $0.bundleURL?.pathExtension == "app"
        }
        func names(_ app: NSRunningApplication) -> [String] {
            [app.localizedName, app.bundleURL?.deletingPathExtension().lastPathComponent, app.bundleIdentifier]
                .compactMap { $0 }.map(Self.normalized)
        }
        var matches = running.filter { names($0).contains(key) }
        if matches.isEmpty, key.count >= 4 {
            matches = running.filter { names($0).contains { $0.hasPrefix(key) } }
            if matches.isEmpty { matches = running.filter { names($0).contains { $0.contains(key) } } }
        }
        guard !matches.isEmpty else { return .failure("\(requested) isn't running, or I couldn't find a running app with that name.") }
        let bundles = Set(matches.compactMap { $0.bundleURL?.standardizedFileURL })
        guard bundles.count == 1 else {
            let options = Set(matches.compactMap(\.localizedName)).sorted().joined(separator: ", ")
            return .failure("More than one running app matches \(requested): \(options). Use the full application name.")
        }
        guard !matches.contains(where: { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier || $0.bundleIdentifier == Bundle.main.bundleIdentifier }) else {
            return .failure("Use Quit IVY in the IVY menu to close IVY itself.")
        }
        guard !matches.contains(where: { $0.bundleIdentifier == "com.apple.finder" }) else {
            return .failure("Finder is managed by macOS and relaunches when force quit.")
        }
        let appName = matches.first?.localizedName ?? requested
        try Task.checkCancellation()
        for app in matches where !app.isTerminated {
            guard app.forceTerminate() || app.isTerminated else {
                return .failure("macOS couldn't force quit \(appName).")
            }
        }
        for _ in 0..<20 {
            if matches.allSatisfy(\.isTerminated) {
                return ToolResult(summary: "Force quit \(appName).", historyTitle: "Force Quit \(appName)")
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        return .failure("I requested a force quit, but couldn't confirm that \(appName) exited.")
    }

    private static func normalized(_ value: String) -> String {
        let name = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+(app|application)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.app$"#, with: "", options: .regularExpression)
        return (AppLauncher.aliases[name] ?? name).filter { !$0.isWhitespace }
    }
}
