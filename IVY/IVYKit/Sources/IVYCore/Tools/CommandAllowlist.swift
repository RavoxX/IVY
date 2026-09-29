import Foundation

/// Allowlisted command execution. The model may only pick a command *identifier* and a
/// directory; the executable and argument vector are fixed here. Nothing the model writes
/// is ever passed to `/bin/sh`, `zsh`, AppleScript or a terminal.
public struct AllowlistedCommand: Sendable, Equatable {
    public var id: String
    public var summary: String
    public var executable: String
    public var arguments: [String]
    public var risk: RiskLevel
    /// Whether the command needs a working directory (validated to exist and be a folder).
    public var needsDirectory: Bool

    public init(id: String, summary: String, executable: String, arguments: [String], risk: RiskLevel,
                needsDirectory: Bool) {
        self.id = id
        self.summary = summary
        self.executable = executable
        self.arguments = arguments
        self.risk = risk
        self.needsDirectory = needsDirectory
    }
}

public enum CommandAllowlist {
    public static let commands: [AllowlistedCommand] = [
        AllowlistedCommand(id: "git_status", summary: "Show git status", executable: "/usr/bin/git",
                           arguments: ["status", "--short", "--branch"], risk: .low, needsDirectory: true),
        AllowlistedCommand(id: "git_log", summary: "Show the last 10 commits", executable: "/usr/bin/git",
                           arguments: ["log", "--oneline", "-10"], risk: .low, needsDirectory: true),
        AllowlistedCommand(id: "git_pull", summary: "Pull the latest changes", executable: "/usr/bin/git",
                           arguments: ["pull", "--ff-only"], risk: .high, needsDirectory: true),
        AllowlistedCommand(id: "disk_usage", summary: "Show free disk space", executable: "/bin/df",
                           arguments: ["-h", "/"], risk: .low, needsDirectory: false),
        AllowlistedCommand(id: "npm_install", summary: "Install npm dependencies", executable: "/usr/bin/env",
                           arguments: ["npm", "install"], risk: .high, needsDirectory: true),
        AllowlistedCommand(id: "brew_update", summary: "Update Homebrew", executable: "/usr/bin/env",
                           arguments: ["brew", "update"], risk: .high, needsDirectory: false),
        AllowlistedCommand(id: "empty_trash_preview", summary: "Show the size of the Trash", executable: "/usr/bin/du",
                           arguments: ["-sh", NSHomeDirectory() + "/.Trash"], risk: .low, needsDirectory: false),
    ]

    public static func command(id: String) -> AllowlistedCommand? {
        commands.first { $0.id == id }
    }

    /// Paths that file-mutating tools must never touch.
    public static let protectedPrefixes: [String] = [
        "/System", "/Library", "/bin", "/sbin", "/usr", "/private", "/etc", "/var", "/Applications",
        "/opt", "/cores", "/Volumes/Macintosh HD",
    ]

    /// Validates a user/model-supplied path for a destructive operation (e.g. move to Trash).
    /// Only files inside the home folder are eligible, and never the home folder itself
    /// or top-level folders like ~/Documents.
    public static func validateDestructivePath(_ raw: String, home: String = NSHomeDirectory()) -> Result<URL, ToolError> {
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        let path = url.path
        let homePath = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(homePath + "/") else {
            return .failure(.invalidArgument("path", "only files inside your home folder can be removed"))
        }
        if protectedPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .failure(.invalidArgument("path", "this location is protected"))
        }
        let relative = path.dropFirst(homePath.count + 1)
        if !relative.contains("/") {
            return .failure(.invalidArgument("path", "top-level home folders are protected"))
        }
        if relative.hasPrefix("Library/") {
            return .failure(.invalidArgument("path", "the Library folder is protected"))
        }
        return .success(url)
    }
}
