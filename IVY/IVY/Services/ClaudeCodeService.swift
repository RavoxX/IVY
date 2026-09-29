import os
import AppKit
import Combine
import IVYCore

/// Starts coding-agent sessions (Claude Code, Codex CLI) in a project folder.
///
/// * Terminal mode opens an interactive session in Terminal.
/// * Background mode runs the agent headless (`claude -p`) and pops the result up in the
///   notch when it finishes.
///
/// The task text is passed as a single argv element or read from a file — it is never
/// interpolated into a shell command line.
@MainActor
final class ClaudeCodeService: ObservableObject {
    enum Agent: String, CaseIterable, Sendable {
        case claude, codex

        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            }
        }
    }

    @Published private(set) var sessions: [CodingSessionInfo] = []
    @Published private(set) var detected: [Agent: URL] = [:]

    var onSessionFinished: ((CodingSessionInfo) -> Void)?

    private let settings: SettingsStore
    private var processes: [UUID: Process] = [:]

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var projectsFolder: URL {
        let raw = settings.string(.codingProjectsFolder)
        return URL(fileURLWithPath: ((raw.isEmpty ? "~/IVY Projects" : raw) as NSString).expandingTildeInPath,
                   isDirectory: true)
    }

    // MARK: - Detection

    func refreshDetection() async {
        for agent in Agent.allCases {
            detected[agent] = await Self.locate(agent)
        }
    }

    func executable(for agent: Agent) async -> URL? {
        if let url = detected[agent], FileManager.default.isExecutableFile(atPath: url.path) { return url }
        let url = await Self.locate(agent)
        detected[agent] = url
        return url
    }

    nonisolated static func candidatePaths(for agent: Agent) -> [String] {
        let home = NSHomeDirectory()
        let name = agent.rawValue
        var paths = [
            "\(home)/.local/bin/\(name)",
            "\(home)/.claude/local/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)",
            "\(home)/.bun/bin/\(name)",
            "\(home)/.volta/bin/\(name)",
        ]
        paths += nvmBinDirectories().map { "\($0)/\(name)" }
        if agent == .claude {
            // The Claude desktop app ships its own Claude Code CLI.
            let base = "\(home)/Library/Application Support/Claude/claude-code"
            let versions = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [])
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            paths += versions.map { "\(base)/\($0)/claude.app/Contents/MacOS/claude" }
        }
        return paths
    }

    nonisolated static func nvmBinDirectories() -> [String] {
        let base = NSHomeDirectory() + "/.nvm/versions/node"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        return versions.map { "\(base)/\($0)/bin" }
    }

    nonisolated static func locate(_ agent: Agent) async -> URL? {
        for path in candidatePaths(for: agent) where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Fall back to the user's login shell PATH. The command string is a constant.
        let result = await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/zsh"),
                                             arguments: ["-lc", "command -v \(agent.rawValue)"], timeout: 5)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 0, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// PATH for agent processes: node-based CLIs need `node` next to them.
    nonisolated static func agentPATH(for executable: URL) -> String {
        var dirs = [executable.deletingLastPathComponent().path]
        dirs += nvmBinDirectories().prefix(1)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return dirs.joined(separator: ":")
    }

    // MARK: - Sessions

    func start(agent: Agent, projectName: String, task: String, mode: CodingSessionInfo.Mode) async throws -> CodingSessionInfo {
        guard let executable = await executable(for: agent) else {
            throw ToolError.unavailable("\(agent.displayName) isn't installed.")
        }
        let slug = ProjectNameSanitizer.sanitize(projectName)
        let directory = projectsFolder.appendingPathComponent(slug, isDirectory: true)
        let ivyFolder = directory.appendingPathComponent(".ivy", isDirectory: true)
        try FileManager.default.createDirectory(at: ivyFolder, withIntermediateDirectories: true)

        let prompt = """
        \(task)

        (Started by IVY, the user's voice assistant. Work inside this folder: \(directory.path). \
        It may be empty; create the project here and keep it self-contained. When you're done, \
        summarize what you built in one or two sentences.)
        """
        let taskFile = ivyFolder.appendingPathComponent("task.md")
        try prompt.write(to: taskFile, atomically: true, encoding: .utf8)

        var info = CodingSessionInfo(agent: agent.displayName, projectName: slug, directory: directory, task: task,
                                     mode: mode, status: .running)
        switch mode {
        case .terminal:
            try await launchInTerminal(executable: executable, agent: agent, directory: directory, ivyFolder: ivyFolder)
            info.detail = "Opened in Terminal"
        case .background:
            try await launchInBackground(executable: executable, agent: agent, directory: directory, ivyFolder: ivyFolder,
                                         prompt: prompt, info: info)
        }
        sessions.insert(info, at: 0)
        Log.claudeCode.info("Started \(agent.rawValue, privacy: .public) session (\(mode.rawValue, privacy: .public))")
        return info
    }

    private func launchInTerminal(executable: URL, agent: Agent, directory: URL, ivyFolder: URL) async throws {
        let script = ivyFolder.appendingPathComponent("start.command")
        let contents = """
        #!/bin/zsh -l
        # Generated by IVY. The task prompt is read from .ivy/task.md.
        cd -- \(Self.shellQuote(directory.path)) || exit 1
        export PATH=\(Self.shellQuote(Self.agentPATH(for: executable))):"$PATH"
        exec \(Self.shellQuote(executable.path)) "$(cat .ivy/task.md)"
        """
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw ToolError.unavailable("Terminal isn't available.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: configuration)
    }

    private func launchInBackground(executable: URL, agent: Agent, directory: URL, ivyFolder: URL, prompt: String,
                                    info: CodingSessionInfo) async throws {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        switch agent {
        case .claude:
            // Headless mode: file edits inside the project are auto-accepted; shell commands
            // not on Claude Code's allowlist are denied (no unattended arbitrary commands).
            process.arguments = ["-p", prompt, "--output-format", "json", "--permission-mode", "acceptEdits"]
        case .codex:
            process.arguments = ["exec", "--full-auto", "--skip-git-repo-check", prompt]
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.agentPATH(for: executable)
        process.environment = env

        let outputURL = ivyFolder.appendingPathComponent("output.json")
        let logURL = ivyFolder.appendingPathComponent("agent.log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: outputURL)
        process.standardError = try FileHandle(forWritingTo: logURL)
        process.standardInput = FileHandle.nullDevice

        let id = info.id
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in self?.finish(id: id, status: status, outputURL: outputURL, logURL: logURL) }
        }
        try process.run()
        processes[id] = process

        // Verify the agent actually started (e.g. not logged in → exits immediately).
        try await Task.sleep(for: .milliseconds(1500))
        if !process.isRunning && process.terminationStatus != 0 {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let tail = log.split(separator: "\n").suffix(2).joined(separator: " ")
            throw ToolError.failed("\(agent.displayName) exited immediately. \(tail)")
        }
    }

    private func finish(id: UUID, status: Int32, outputURL: URL, logURL: URL) {
        processes.removeValue(forKey: id)
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var info = sessions[index]
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        var summary: String?
        var isError = status != 0
        if let json = JSONValue.parse(output) {
            summary = json["result"]?.stringValue
            if json["is_error"]?.boolValue == true { isError = true }
        } else if !output.isEmpty {
            summary = output.split(separator: "\n").suffix(3).joined(separator: " ")
        }
        info.status = isError ? .failed : .finished
        info.detail = summary.map { String($0.prefix(280)) } ?? (isError ? "The session ended with an error." : "Done.")
        sessions[index] = info
        Log.claudeCode.info("Session finished with status \(status)")
        onSessionFinished?(info)
    }

    func cancel(_ id: UUID) {
        processes[id]?.terminate()
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
