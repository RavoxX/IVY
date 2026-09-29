import Foundation
import IVYCore

/// Starts a coding-agent session (Claude Code by default) for a project.
struct ClaudeCodeTool: IVYTool {
    let service: ClaudeCodeService
    let settings: SettingsStore
    let name = ToolName.startCodingSession
    let description = "Start a Claude Code (or Codex) coding session in a project folder to build or change software."
    let displayName = "Claude Code"
    let baseRisk = RiskLevel.medium
    var parameters: [ToolParameter] {
        [
            ToolParameter("project_name", .string, "Short folder name for the project, e.g. 'personal-website'.", required: true),
            ToolParameter("task", .string, "What the agent should do, as an imperative sentence.", required: true),
            ToolParameter("agent", .string, "Which coding agent to use.", enumValues: ClaudeCodeService.Agent.allCases.map(\.rawValue)),
        ]
    }

    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        let task = try arguments.requiredString("task")
        guard task.count <= 2000 else { throw ToolError.invalidArgument("task", "too long") }
        let project = arguments.string("project_name") ?? ProjectNameSanitizer.projectName(fromTask: task)
        let agent = arguments.string("agent").flatMap { ClaudeCodeService.Agent(rawValue: $0.lowercased()) } ?? .claude
        let mode = settings.codingSessionMode

        let info = try await service.start(agent: agent, projectName: project, task: task, mode: mode)
        let subject = Self.subject(from: task, fallback: info.projectName)
        let summary: String
        switch mode {
        case .background:
            summary = "\(agent.displayName) is building \(subject) in the background. I'll show it here when it's done."
        case .terminal:
            summary = "\(agent.displayName) is working on \(info.projectName) in Terminal."
        }
        return ToolResult(summary: summary, card: .codingSession(info),
                          historyTitle: "\(info.projectName): \(task)")
    }

    /// "Build a personal website" → "your personal website".
    static func subject(from task: String, fallback: String) -> String {
        let pattern = #"^(?i)(build|create|make|write|develop|code|scaffold|implement)\s+(an?|the|my)\s+"#
        guard let range = task.range(of: pattern, options: .regularExpression) else { return fallback }
        let rest = task[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return rest.isEmpty ? fallback : "your \(rest)"
    }
}
