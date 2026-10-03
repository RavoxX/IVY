import Foundation

public struct AssistantRoutine: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var commands: [String]
    public init(id: UUID = UUID(), name: String, commands: [String]) {
        self.id = id; self.name = name; self.commands = commands
    }
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80 &&
        (1...8).contains(commands.count) && commands.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 1000 }
    }
}

public actor RoutineStore {
    private let fileURL: URL
    private var values: [AssistantRoutine]?
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func all() -> [AssistantRoutine] {
        if values == nil {
            values = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([AssistantRoutine].self, from: $0) } ?? []
        }
        return (values ?? []).filter(\.isValid)
    }
    public func save(_ routine: AssistantRoutine) throws {
        guard routine.isValid else { throw ToolError.invalidArgument("routine", "Use a name and 1–8 nonempty steps (up to 1,000 characters each).") }
        var routines = all(); routines.removeAll { $0.id == routine.id }; routines.append(routine); values = Array(routines.suffix(100)); try persist()
    }
    public func remove(_ id: UUID) throws { values = all().filter { $0.id != id }; try persist() }
    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(values ?? []).write(to: fileURL, options: .atomic)
    }
}
