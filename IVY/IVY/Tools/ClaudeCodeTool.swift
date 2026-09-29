import Foundation
import IVYCore

/// Starts a coding-agent session (Claude Code by default) for a project.
struct ClaudeCodeTool: IVYTool {
    let service: ClaudeCodeService
    let settings: SettingsStore
    let name = ToolName.startCodingSession
    let description = "Open Claude Code (or Codex) in Terminal, optionally with a coding task to start on."
    let displayName = "Claude Code"
    let baseRisk = RiskLevel.medium
    var parameters: [ToolParameter] {
        [
            ToolParameter("task", .string, "What the agent should build or change, as an imperative sentence. Omit if the user only wants Claude Code opened."),
            ToolParameter("project_name", .string, "Short folder name, e.g. 'personal-website'. Only when a project is mentioned."),
            ToolParameter("agent", .string, "Which coding agent to use.", enumValues: ClaudeCodeService.Agent.allCases.map(\.rawValue)),
        ]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let task = arguments.string("task")
        if let task, task.count > 2000 { throw ToolError.invalidArgument("task", "too long") }
        let project = arguments.string("project_name") ?? task.map { ProjectNameSanitizer.projectName(fromTask: $0) }
        let agent = arguments.string("agent").flatMap { ClaudeCodeService.Agent(rawValue: $0.lowercased()) } ?? .claude

        let info = try await service.start(agent: agent, projectName: project, task: task, mode: settings.codingSessionMode)
        let summary: String
        switch (task, info.mode) {
        case (nil, _):
            summary = "Opened \(agent.displayName) in Terminal."
        case (let task?, .background):
            summary = "\(agent.displayName) is building \(Self.subject(from: task, fallback: info.projectName)) in the background. I'll show it here when it's done."
        case (_?, .terminal):
            summary = "\(agent.displayName) is working on \(info.projectName) in Terminal."
        }
        return ToolResult(summary: summary, card: .codingSession(info),
                          historyTitle: task.map { "\(info.projectName): \($0)" } ?? agent.displayName)
    }

    /// "Build a personal website" → "your personal website".
    static func subject(from task: String, fallback: String) -> String {
        let pattern = #"^(?i)(build|create|make|write|develop|code|scaffold|implement)\s+(an?|the|my)\s+"#
        guard let range = task.range(of: pattern, options: .regularExpression) else { return fallback }
        let rest = task[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return rest.isEmpty ? fallback : "your \(rest)"
    }
}
