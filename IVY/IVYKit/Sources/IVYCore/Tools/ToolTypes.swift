import Foundation

// MARK: - Tool calls

/// A structured request from the model (or the fast command router) to run a tool.
public struct ToolCall: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var arguments: [String: JSONValue]

    public init(id: String = UUID().uuidString, name: String, arguments: [String: JSONValue] = [:]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public static func == (lhs: ToolCall, rhs: ToolCall) -> Bool {
        lhs.name == rhs.name && lhs.arguments == rhs.arguments
    }
}

// MARK: - Risk

/// Risk classes for actions. High-risk actions always require explicit user confirmation.
public enum RiskLevel: Int, Sendable, Comparable, Codable, CaseIterable {
    case low = 0
    case medium = 1
    case high = 2

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

// MARK: - Results

public struct ToolResult: Sendable, Equatable {
    public enum Status: String, Sendable, Codable { case success, failure, cancelled }

    public var status: Status
    /// Short, factual, model-readable summary. Also shown to the user when the tool is terminal.
    public var summary: String
    /// Optional structured data for the model (kept compact).
    public var data: JSONValue?
    public var card: ResultCard?
    /// Title used in the history list, e.g. "Daily Reminder Overview".
    public var historyTitle: String?

    public init(status: Status = .success, summary: String, data: JSONValue? = nil, card: ResultCard? = nil,
                historyTitle: String? = nil) {
        self.status = status
        self.summary = summary
        self.data = data
        self.card = card
        self.historyTitle = historyTitle
    }

    public static func failure(_ message: String) -> ToolResult {
        ToolResult(status: .failure, summary: message)
    }

    /// The text sent back to the model as the tool response.
    public var modelPayload: String {
        var object: [String: JSONValue] = ["status": .string(status.rawValue), "summary": .string(summary)]
        if let data { object["data"] = data }
        return JSONValue.object(object).jsonString()
    }
}

public enum ToolError: LocalizedError, Sendable, Equatable {
    case unknownTool(String)
    case missingArgument(String)
    case invalidArgument(String, String)
    case permissionDenied(String)
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "Unknown tool \(name)."
        case .missingArgument(let name): return "Missing argument '\(name)'."
        case .invalidArgument(let name, let reason): return "Invalid '\(name)': \(reason)"
        case .permissionDenied(let what): return "\(what) permission is not granted."
        case .unavailable(let reason): return reason
        case .failed(let reason): return reason
        }
    }
}

// MARK: - Schema

/// A minimal JSON-schema description of a tool parameter, rendered into the
/// OpenAI-style function schema that Qwen3's chat template understands.
public struct ToolParameter: Sendable, Equatable {
    public enum Kind: String, Sendable { case string, integer, number, boolean }

    public var name: String
    public var kind: Kind
    public var description: String
    public var required: Bool
    public var enumValues: [String]?

    public init(_ name: String, _ kind: Kind = .string, _ description: String, required: Bool = false,
                enumValues: [String]? = nil) {
        self.name = name
        self.kind = kind
        self.description = description
        self.required = required
        self.enumValues = enumValues
    }
}

// MARK: - Tool protocol

public struct ToolContext: Sendable {
    public var now: Date
    public var originalQuery: String

    public init(now: Date = Date(), originalQuery: String = "") {
        self.now = now
        self.originalQuery = originalQuery
    }
}

/// Every capability IVY exposes to the model is an `IVYTool`. Tools receive validated,
/// structured arguments — never raw model text destined for a shell.
public protocol IVYTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: [ToolParameter] { get }
    /// Human readable label shown while the tool runs ("Spotify", "Reminders", …).
    var displayName: String { get }
    var baseRisk: RiskLevel { get }
    /// When true the tool's summary is already a good final answer, so IVY skips a
    /// second model pass. Saves latency on a fanless MacBook Air.
    var isTerminal: Bool { get }
    /// When true the summary only reports what the tool did ("Found 5 web results"), so even
    /// a fast-routed call goes back to the model to answer from the result's data.
    var requiresModelAnswer: Bool { get }

    /// Risk may depend on the arguments (e.g. an allowlisted command).
    func risk(for arguments: [String: JSONValue]) -> RiskLevel
    /// Human-readable description of what will happen, used on confirmation cards.
    func confirmationPrompt(for arguments: [String: JSONValue]) -> String
    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult
}

public extension IVYTool {
    var isTerminal: Bool { true }
    var requiresModelAnswer: Bool { false }
    func risk(for arguments: [String: JSONValue]) -> RiskLevel { baseRisk }
    func confirmationPrompt(for arguments: [String: JSONValue]) -> String {
        "Allow IVY to run \(displayName)?"
    }

    /// OpenAI-style function schema (as used by Qwen3 / Hugging Face chat templates).
    var schema: JSONValue {
        var properties: [String: JSONValue] = [:]
        for parameter in parameters {
            var property: [String: JSONValue] = [
                "type": .string(parameter.kind.rawValue),
                "description": .string(parameter.description),
            ]
            if let values = parameter.enumValues {
                property["enum"] = .array(values.map { .string($0) })
            }
            properties[parameter.name] = .object(property)
        }
        return [
            "type": "function",
            "function": [
                "name": .string(name),
                "description": .string(description),
                "parameters": [
                    "type": "object",
                    "properties": .object(properties),
                    "required": .array(parameters.filter(\.required).map { .string($0.name) }),
                ],
            ],
        ]
    }
}

// MARK: - Argument helpers

public extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        guard let value = self[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else { throw ToolError.missingArgument(key) }
        return value
    }

    func int(_ key: String) -> Int? {
        self[key]?.doubleValue.map { Int($0.rounded()) }
    }

    func bool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }
}
