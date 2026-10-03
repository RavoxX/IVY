import Combine
import Foundation
import IVYCore
import Security

struct ConnectorAccount: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var endpoint: URL
    var enabledTools: [String] = []
    var accountLabel = ""
    var keychainAccount: String { "mcp.\(id.uuidString)" }
}

@MainActor
final class ConnectorManager: ObservableObject {
    @Published private(set) var accounts: [ConnectorAccount] = []
    @Published private(set) var tools: [UUID: [MCPToolDefinition]] = [:]
    @Published private(set) var status: [UUID: String] = [:]
    @Published private(set) var busy = Set<UUID>()
    let oauth = ConnectorOAuth()
    private let registry: ToolRegistry
    private var clients: [UUID: MCPClient] = [:]
    private var epochs: [UUID: UUID] = [:]
    private var signingIn = false
    private let file = AppPaths.applicationSupport.appendingPathComponent("connectors.json")

    init(registry: ToolRegistry) {
        self.registry = registry
        accounts = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([ConnectorAccount].self, from: $0) } ?? []
        for account in accounts { status[account.id] = "Disconnected — connect to use" }
    }
    func add(name: String, endpoint: URL) throws -> UUID {
        guard MCPURL.validate(endpoint), !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw MCPError.invalidURL }
        let account = ConnectorAccount(name: String(name.prefix(80)), endpoint: endpoint)
        accounts.append(account); persist(); return account.id
    }
    func setToken(_ token: String, id: UUID) throws {
        guard let account = accounts.first(where: { $0.id == id }), !token.contains(where: { $0.isNewline }) else { throw MCPError.authentication }
        guard Keychain.write(token, account: account.keychainAccount) == errSecSuccess else { throw ToolError.failed("Keychain couldn't save this token.") }
    }
    func signIn(id: UUID, clientID: String, clientSecret: String, scope: String) async {
        guard let account = accounts.first(where: { $0.id == id }), !busy.contains(id), !signingIn else { return }
        signingIn = true
        busy.insert(id); status[id] = "Waiting for browser sign-in…"
        let epoch = UUID(); epochs[id] = epoch
        defer { busy.remove(id); signingIn = false }
        do {
            let grant = try await oauth.signIn(endpoint: account.endpoint, clientID: clientID, clientSecret: clientSecret, scope: scope)
            guard epochs[id] == epoch, accounts.contains(where: { $0.id == id }) else { return }
            guard let text = String(data: try JSONEncoder().encode(grant), encoding: .utf8),
                  Keychain.write(text, account: account.keychainAccount + ".oauth") == errSecSuccess else { throw ToolError.failed("Keychain couldn't save this account.") }
            status[id] = "Signed in"; busy.remove(id)
            await connect(id)
        } catch is CancellationError { status[id] = "Sign-in cancelled" }
        catch { status[id] = error.localizedDescription }
    }
    func connect(_ id: UUID) async {
        guard let account = accounts.first(where: { $0.id == id }), !busy.contains(id) else { return }
        busy.insert(id); status[id] = "Connecting…"
        let epoch = UUID(); epochs[id] = epoch
        defer { busy.remove(id) }
        unregister(id)
        if let previous = clients.removeValue(forKey: id) { await previous.disconnect() }
        do {
            var token = Keychain.read(account: account.keychainAccount) ?? ""
            if let data = Keychain.read(account: account.keychainAccount + ".oauth")?.data(using: .utf8),
               var grant = try? JSONDecoder().decode(ConnectorOAuth.Grant.self, from: data) {
                if let expires = grant.expiresAt, expires < Date().addingTimeInterval(60) {
                    grant = try await oauth.refresh(grant)
                    guard let text = String(data: try JSONEncoder().encode(grant), encoding: .utf8),
                          Keychain.write(text, account: account.keychainAccount + ".oauth") == errSecSuccess else { throw MCPError.authentication }
                }
                token = grant.accessToken
            }
            let client = try MCPClient(endpoint: account.endpoint, token: token)
            let discovered = try await client.connect()
            guard epochs[id] == epoch, accounts.contains(where: { $0.id == id }) else { await client.disconnect(); return }
            clients[id] = client; tools[id] = discovered
            status[id] = "Connected · \(discovered.count) tools"
            register(id)
        } catch { if epochs[id] == epoch { status[id] = error.localizedDescription } }
    }
    func setEnabled(_ enabled: Bool, tool: String, id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }), tools[id]?.contains(where: { $0.name == tool }) == true else { return }
        accounts[index].enabledTools.removeAll { $0 == tool }
        if enabled {
            guard accounts[index].enabledTools.count < 24 else { status[id] = "Enable up to 24 tools per account to keep the model context manageable."; return }
            accounts[index].enabledTools.append(tool)
        }
        unregister(id); register(id); persist()
    }
    func disconnect(_ id: UUID, remove: Bool = false, revoke: Bool = false) async {
        epochs[id] = UUID(); oauth.cancel(); unregister(id)
        let account = accounts.first { $0.id == id }
        let client = clients.removeValue(forKey: id); tools.removeValue(forKey: id)
        status[id] = "Disconnected"; busy.remove(id)
        if let client { await client.disconnect() }
        if revoke, let account,
           let data = Keychain.read(account: account.keychainAccount + ".oauth")?.data(using: .utf8),
           let grant = try? JSONDecoder().decode(ConnectorOAuth.Grant.self, from: data) {
            do { try await oauth.revoke(grant); status[id] = "Access revoked" }
            catch { status[id] = error.localizedDescription }
        }
        if remove || revoke, let account {
            _ = Keychain.write("", account: account.keychainAccount)
            _ = Keychain.write("", account: account.keychainAccount + ".oauth")
        }
        if remove { accounts.removeAll { $0.id == id }; persist() }
    }
    func call(id: UUID, tool: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        guard let account = accounts.first(where: { $0.id == id }), account.enabledTools.contains(tool) else { throw MCPError.disconnected }
        if let data = Keychain.read(account: account.keychainAccount + ".oauth")?.data(using: .utf8),
           let grant = try? JSONDecoder().decode(ConnectorOAuth.Grant.self, from: data),
           let expires = grant.expiresAt, expires < Date().addingTimeInterval(60) {
            // Refresh before executing. Never replay a tool call after an ambiguous failure.
            await connect(id)
        }
        guard let client = clients[id] else { throw MCPError.disconnected }
        return try await client.call(name: tool, arguments: arguments)
    }
    private func alias(_ id: UUID, index: Int) -> String { "mcp_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() + "_\(index)" }
    private func unregister(_ id: UUID) { registry.remove(names: (tools[id] ?? []).indices.map { alias(id, index: $0) }) }
    private func register(_ id: UUID) {
        guard clients[id] != nil, let account = accounts.first(where: { $0.id == id }) else { return }
        for (index, tool) in (tools[id] ?? []).enumerated() where account.enabledTools.contains(tool.name) {
            registry.register(ConnectorTool(name: alias(id, index: index), account: account, definition: tool, manager: self))
        }
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

private struct ConnectorTool: IVYTool {
    let name: String
    let account: ConnectorAccount
    let definition: MCPToolDefinition
    let manager: ConnectorManager
    var description: String { "\(account.name): \(definition.description)" }
    var displayName: String { "\(account.name) · \(definition.name)" }
    let parameters: [ToolParameter] = []
    // Server annotations never grant trust. Every remote action shows its arguments first.
    let baseRisk = RiskLevel.high
    let isTerminal = false
    var schema: JSONValue {
        ["type": "function", "function": ["name": .string(name), "description": .string(description), "parameters": definition.inputSchema]]
    }
    func confirmationPrompt(for arguments: [String: JSONValue]) -> String {
        "Run \(definition.name) on \(account.name) (\(account.endpoint.host ?? ""))?\n\n" + JSONValue.object(arguments).jsonString()
    }
    func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult {
        try MCPArgumentValidator.validate(arguments, schema: definition.inputSchema)
        let result = try await manager.call(id: account.id, tool: definition.name, arguments: arguments)
        let failed = result["isError"]?.boolValue == true
        let text = (result["content"]?.arrayValue ?? []).compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined(separator: "\n")
        let summary = failed ? "\(account.name) reported that \(definition.name) failed." : "\(account.name) returned a result for \(definition.name)."
        var data: [String: JSONValue] = ["text": .string(ContextBudget.clip(text, 12_000)), "origin": .string(account.endpoint.absoluteString)]
        if let structured = result["structuredContent"] { data["structuredContent"] = structured }
        return ToolResult(status: failed ? .failure : .success, summary: summary, data: .object(data), historyTitle: displayName)
    }
}
