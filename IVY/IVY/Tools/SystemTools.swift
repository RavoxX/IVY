import AppKit
import IVYCore

struct OpenApplicationTool: IVYTool {
    let launcher: AppLauncher
    let name = ToolName.openApp
    let description = "Open (launch) an application installed on this Mac."
    let displayName = "Open App"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [ToolParameter("name", .string, "Application name, e.g. 'Safari' or 'Visual Studio Code'.", required: true)]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let requested = try arguments.requiredString("name")
        guard let app = launcher.resolve(requested) else {
            return .failure("I couldn't find an app called \(requested).")
        }
        try await launcher.open(app.url)
        return ToolResult(summary: "Opened \(app.name).", card: .appLaunched(name: app.name, bundlePath: app.url.path),
                          historyTitle: "Open \(app.name)")
    }
}

struct OpenURLTool: IVYTool {
    let name = ToolName.openURL
    let description = "Open a website in the default browser."
    let displayName = "Open Website"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [ToolParameter("url", .string, "The web address, e.g. 'github.com' or 'https://apple.com'.", required: true)]
    }

    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let raw = try arguments.requiredString("url")
        guard let url = Self.normalize(raw) else { throw ToolError.invalidArgument("url", "only web addresses are allowed") }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { return .failure("I couldn't open \(url.host ?? raw).") }
        let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? raw
        return ToolResult(summary: "Opened \(host).", card: .link(title: host, url: url), historyTitle: "Open \(host)")
    }
}

/// Maps spoken folder names and paths to file URLs inside the user's disk.
enum FilePathResolver {
    static func resolve(_ raw: String) -> URL? {
        let key = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+(folder|directory)$"#, with: "", options: .regularExpression)
        if let known = CommandRouter.knownFolders[key] {
            return URL(fileURLWithPath: (known as NSString).expandingTildeInPath)
        }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

struct OpenFileTool: IVYTool {
    let name = ToolName.openFile
    let description = "Open a file or folder (folders open in Finder). Accepts paths like '~/Downloads' or names like 'Documents'."
    let displayName = "Finder"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [ToolParameter("path", .string, "Absolute path, ~ path, or a standard folder name.", required: true)]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let raw = try arguments.requiredString("path")
        guard let url = FilePathResolver.resolve(raw) else { return .failure("I couldn't find \(raw).") }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { return .failure("I couldn't open \(url.lastPathComponent).") }
        let name = FileManager.default.displayName(atPath: url.path)
        return ToolResult(summary: "Opened \(name).", card: .file(url: url), historyTitle: "Open in Finder")
    }
}

struct RevealInFinderTool: IVYTool {
    let name = ToolName.revealInFinder
    let description = "Show a file in Finder (select it in its folder)."
    let displayName = "Finder"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [ToolParameter("path", .string, "Absolute or ~ path of the file.", required: true)]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let raw = try arguments.requiredString("path")
        guard let url = FilePathResolver.resolve(raw) else { return .failure("I couldn't find \(raw).") }
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        return ToolResult(summary: "Showing \(url.lastPathComponent) in Finder.", card: .file(url: url),
                          historyTitle: "Open in Finder")
    }
}

struct SettingsTool: IVYTool {
    let open: @Sendable (String?) async -> Void
    let name = ToolName.openSettings
    let description = "Open IVY's own Settings window."
    let displayName = "IVY Settings"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [ToolParameter("section", .string, "Optional section to show.",
                       enumValues: ["general", "ai", "voice", "shortcuts", "integrations", "privacy", "advanced"])]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let section = arguments.string("section")?.lowercased()
        await open(section)
        return ToolResult(summary: "Opening IVY Settings.", card: .settings(section: section), historyTitle: "IVY Settings")
    }
}

struct MoveToTrashTool: IVYTool {
    let name = ToolName.moveToTrash
    let description = "Move a file in the user's home folder to the Trash (recoverable). Always requires confirmation."
    let displayName = "Move to Trash"
    let baseRisk = RiskLevel.high
    var parameters: [ToolParameter] {
        [ToolParameter("path", .string, "Absolute or ~ path of the file.", required: true)]
    }

    func confirmationPrompt(for arguments: [String: JSONValue]) -> String {
        let path = arguments.string("path") ?? "this file"
        return "Move “\((path as NSString).abbreviatingWithTildeInPath)” to the Trash?"
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let raw = try arguments.requiredString("path")
        let url: URL
        switch CommandAllowlist.validateDestructivePath(raw) {
        case .success(let valid): url = valid
        case .failure(let error): throw error
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure("That file doesn't exist.") }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        return ToolResult(summary: "Moved \(url.lastPathComponent) to the Trash.", historyTitle: "Move to Trash")
    }
}

struct RunCommandTool: IVYTool {
    let name = ToolName.runCommand
    let description = "Run one of IVY's allowlisted maintenance commands (no arbitrary shell)."
    let displayName = "Command"
    let baseRisk = RiskLevel.high
    let isTerminal = false
    var parameters: [ToolParameter] {
        [
            ToolParameter("command", .string, "Command id.", required: true, enumValues: CommandAllowlist.commands.map(\.id)),
            ToolParameter("directory", .string, "Working directory (required for git/npm commands)."),
        ]
    }

    func risk(for arguments: [String: JSONValue]) -> RiskLevel {
        arguments.string("command").flatMap(CommandAllowlist.command(id:))?.risk ?? .high
    }

    func confirmationPrompt(for arguments: [String: JSONValue]) -> String {
        guard let command = arguments.string("command").flatMap(CommandAllowlist.command(id:)) else {
            return "Run an unknown command?"
        }
        let directory = arguments.string("directory").map { " in \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? ""
        let rendered = ([command.executable.split(separator: "/").last.map(String.init) ?? ""] + command.arguments)
            .filter { $0 != "env" }.joined(separator: " ")
        return "\(command.summary)? (\(rendered)\(directory))"
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let id = try arguments.requiredString("command")
        guard let command = CommandAllowlist.command(id: id) else {
            throw ToolError.invalidArgument("command", "not on the allowlist")
        }
        var directory: URL?
        if command.needsDirectory {
            let raw = try arguments.requiredString("directory")
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard url.path.hasPrefix(NSHomeDirectory() + "/"),
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ToolError.invalidArgument("directory", "must be an existing folder in your home folder")
            }
            directory = url
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let result = await ProcessRunner.run(executable: URL(fileURLWithPath: command.executable), arguments: command.arguments,
                                             environment: env, currentDirectory: directory, timeout: 120)
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(output.suffix(800))
        let status: ToolResult.Status = result.status == 0 ? .success : .failure
        return ToolResult(status: status,
                          summary: status == .success ? "\(command.summary): done." : "\(command.summary) failed.",
                          data: ["output": .string(trimmed)],
                          card: .list(title: command.summary, rows: trimmed.split(separator: "\n").prefix(12).map(String.init)),
                          historyTitle: "Run Command")
    }
}
