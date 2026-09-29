import Foundation

/// Central registry of tools available to the agent. Adding an integration is a matter of
/// implementing `IVYTool` and registering it here.
public final class ToolRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tools: [String: any IVYTool] = [:]
    private var order: [String] = []

    public init(tools: [any IVYTool] = []) {
        tools.forEach(register)
    }

    public func register(_ tool: any IVYTool) {
        lock.lock(); defer { lock.unlock() }
        if tools[tool.name] == nil { order.append(tool.name) }
        tools[tool.name] = tool
    }

    public func tool(named name: String) -> (any IVYTool)? {
        lock.lock(); defer { lock.unlock() }
        return tools[name] ?? tools[Self.normalize(name)]
    }

    public var allTools: [any IVYTool] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { tools[$0] }
    }

    public var schemas: [JSONValue] { allTools.map(\.schema) }

    /// Models occasionally emit `Music.Play` or `music-play`; map those to `music_play`.
    static func normalize(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}

/// Decides whether an action needs explicit confirmation.
public struct SecurityPolicy: Sendable {
    /// Actions at or above this level require confirmation. High risk is always confirmed.
    public var confirmationThreshold: RiskLevel

    public init(confirmationThreshold: RiskLevel = .high) {
        // Never allow disabling confirmation for high risk actions.
        self.confirmationThreshold = min(confirmationThreshold, .high)
    }

    public func requiresConfirmation(_ risk: RiskLevel) -> Bool {
        risk >= confirmationThreshold
    }

    public func requiresConfirmation(tool: any IVYTool, arguments: [String: JSONValue]) -> Bool {
        requiresConfirmation(tool.risk(for: arguments))
    }
}
