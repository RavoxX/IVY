import Combine
import Foundation
import IVYCore

/// Undo records are created by successful built-in tools, never by the model.
@MainActor
final class UndoStore: ObservableObject {
    struct Record: Identifiable {
        let id = UUID()
        let label: String
        let createdAt = Date()
        let action: @Sendable () async throws -> String
    }
    @Published private(set) var records: [Record] = []
    private var running = false
    func add(label: String, action: @escaping @Sendable () async throws -> String) {
        records.removeAll { Date().timeIntervalSince($0.createdAt) > 1800 }
        records.append(Record(label: label, action: action))
        if records.count > 20 { records.removeFirst() }
    }
    var latestLabel: String? { records.last?.label }
    func undoLast() async throws -> ToolResult {
        guard !running, let record = records.last, Date().timeIntervalSince(record.createdAt) <= 1800 else {
            throw ToolError.unavailable("There is no recent reversible action to undo.")
        }
        running = true; defer { running = false }
        let text = try await record.action()
        records.removeAll { $0.id == record.id }
        return ToolResult(summary: text, historyTitle: "Undo")
    }
}

struct UndoLastActionTool: IVYTool {
    let store: UndoStore
    let name = ToolName.undoLastAction
    let description = "Undo the most recent reversible built-in action (new reminder, completed reminder, new calendar event or timer). Only tool-created undo records can be used."
    let displayName = "Undo"
    let parameters: [ToolParameter] = []
    let baseRisk = RiskLevel.high
    func confirmationPrompt(for arguments: [String: JSONValue]) -> String { "Undo IVY's most recent reversible action? Check the action list before allowing this." }
    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        guard arguments.isEmpty else { throw ToolError.invalidArgument("undo", "no arguments are accepted") }
        return try await store.undoLast()
    }
}
