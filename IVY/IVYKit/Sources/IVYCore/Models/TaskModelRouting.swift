import Foundation

public enum AITask: String, Codable, CaseIterable, Identifiable, Sendable {
    case commands, research, writing, translation, definitions, grammar
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .commands: return "Commands & planning"
        case .research: return "Web research"
        case .writing: return "Writing & summaries"
        case .translation: return "Translation"
        case .definitions: return "Definitions & synonyms"
        case .grammar: return "Grammar & rewriting"
        }
    }
}
public struct TaskModelChoice: Codable, Sendable, Equatable {
    public var provider: AIProvider
    public var model: String
    public init(provider: AIProvider, model: String) { self.provider = provider; self.model = model }
}
public extension SettingsStore {
    var taskModelChoices: [String: TaskModelChoice] {
        string(.taskModels).data(using: .utf8).flatMap { try? JSONDecoder().decode([String: TaskModelChoice].self, from: $0) } ?? [:]
    }
    func setTaskModel(_ choice: TaskModelChoice?, for task: AITask) {
        var values = taskModelChoices; values[task.rawValue] = choice
        if let data = try? JSONEncoder().encode(values) { set(String(decoding: data, as: UTF8.self), for: .taskModels) }
    }
    func modelChoice(for task: AITask) -> TaskModelChoice {
        if let choice = taskModelChoices[task.rawValue] { return choice }
        if task != .commands, let provider = AIProvider(rawValue: string(.writingProvider)), provider != .local {
            return TaskModelChoice(provider: provider, model: cloudModel(for: provider))
        }
        let main = taskModelChoices[AITask.commands.rawValue] ?? TaskModelChoice(provider: aiProvider, model: aiProvider == .local ? string(.llmModelID) : cloudModel(for: aiProvider))
        if task != .commands, main.provider == .local, !string(.writingModelID).isEmpty {
            return TaskModelChoice(provider: .local, model: string(.writingModelID))
        }
        return main
    }
    var routingMode: String {
        let providers = Set(AITask.allCases.map { modelChoice(for: $0).provider })
        if providers == [.local] { return "Local" }
        if providers.contains(.local) { return "Hybrid" }
        return "Cloud"
    }
}
