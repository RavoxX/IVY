import Foundation

public enum MCPError: LocalizedError, Sendable {
    case invalidURL, authentication, http(Int), protocolError, serverError, oversized, disconnected
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Use an HTTPS MCP endpoint, or HTTP on localhost. Credentials belong in the authentication fields."
        case .authentication: return "Sign in or add a token to connect to this server."
        case .http(let code): return "The connector returned HTTP \(code). Check its setup and account permissions."
        case .protocolError: return "This server returned an unsupported MCP response."
        case .serverError: return "The server reported that the request failed."
        case .oversized: return "The connector response exceeded IVY's size limit."
        case .disconnected: return "This connector is disconnected or the tool is disabled."
        }
    }
}

public enum MCPURL {
    public static func validate(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
              let host = url.host, !host.isEmpty else { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
    }
}

public struct MCPToolDefinition: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let readOnlyHint: Bool
    public init?(_ value: JSONValue) {
        guard let name = value["name"]?.stringValue, !name.isEmpty, name.count <= 128,
              let schema = value["inputSchema"], schema["type"]?.stringValue == "object" else { return nil }
        self.name = name; description = String((value["description"]?.stringValue ?? name).prefix(2000))
        inputSchema = schema; readOnlyHint = value["annotations"]?["readOnlyHint"]?.boolValue == true
    }
}

/// No redirects: credentials and MCP session IDs are bound to the exact endpoint.
public final class MCPRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    public static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: MCPRedirectGuard(), delegateQueue: nil)
    }
}

/// Streamable HTTP MCP client. Tool calls are never automatically replayed on failure.
public actor MCPClient {
    public let endpoint: URL
    private let token: String
    private let session: URLSession
    private var sessionID: String?
    private var version = "2025-11-25"
    private var nextID = 0
    private var initialized = false
    public init(endpoint: URL, token: String = "", session: URLSession = MCPRedirectGuard.session()) throws {
        guard MCPURL.validate(endpoint), !token.contains(where: { $0.isNewline }) else { throw MCPError.invalidURL }
        self.endpoint = endpoint; self.token = token; self.session = session
    }

    public func connect() async throws -> [MCPToolDefinition] {
        let result = try await rpc("initialize", params: ["protocolVersion": .string(version), "capabilities": [:],
            "clientInfo": ["name": "IVY", "version": "2.0"]])
        guard let negotiated = result["protocolVersion"]?.stringValue,
              ["2025-03-26", "2025-06-18", "2025-11-25"].contains(negotiated) else { throw MCPError.protocolError }
        version = negotiated
        try await notify("notifications/initialized", params: [:])
        initialized = true
        var tools: [MCPToolDefinition] = []; var cursor: String?
        for _ in 0..<10 {
            let page = try await rpc("tools/list", params: cursor.map { ["cursor": .string($0)] } ?? [:])
            tools += (page["tools"]?.arrayValue ?? []).compactMap(MCPToolDefinition.init)
            guard tools.count <= 200 else { throw MCPError.oversized }
            cursor = page["nextCursor"]?.stringValue
            if cursor == nil || cursor == "" { break }
        }
        guard cursor == nil || cursor == "" else { throw MCPError.oversized }
        var seen = Set<String>()
        return tools.filter { seen.insert($0.name).inserted }
    }

    public func call(name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        guard initialized else { throw MCPError.disconnected }
        guard JSONValue.object(arguments).jsonString().utf8.count <= 256_000 else { throw MCPError.oversized }
        return try await rpc("tools/call", params: ["name": .string(name), "arguments": .object(arguments)])
    }

    public func disconnect() async {
        initialized = false
        if sessionID != nil {
            var request = request(); request.httpMethod = "DELETE"
            _ = try? await session.data(for: request)
        }
        session.invalidateAndCancel(); sessionID = nil
    }

    private func request() -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
        request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        return request
    }

    private func notify(_ method: String, params: [String: JSONValue]) async throws {
        var request = request()
        request.httpBody = try JSONEncoder().encode(JSONValue.object(["jsonrpc": "2.0", "method": .string(method), "params": .object(params)]))
        let (_, response) = try await session.data(for: request)
        try check(response)
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw MCPError.protocolError }
        if http.statusCode == 401 || http.statusCode == 403 { throw MCPError.authentication }
        guard (200..<300).contains(http.statusCode) else { throw MCPError.http(http.statusCode) }
    }

    private func rpc(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        nextID += 1; let id = nextID
        var request = request()
        request.httpBody = try JSONEncoder().encode(JSONValue.object(["jsonrpc": "2.0", "id": .number(Double(id)),
            "method": .string(method), "params": .object(params)]))
        let (bytes, response) = try await session.bytes(for: request)
        try check(response)
        if method == "initialize", let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "MCP-Session-Id") {
            guard header.utf8.allSatisfy({ (0x21...0x7e).contains($0) }), header.count <= 4096 else { throw MCPError.protocolError }
            sessionID = header
        }
        if response.mimeType == "text/event-stream" {
            var frames = SSEFrameDecoder(limit: 2_000_000)
            for try await byte in bytes {
                try Task.checkCancellation()
                if let payload = try frames.receive(byte) {
                    if let value = JSONValue.parse(payload), value["id"]?.doubleValue == Double(id) { return try result(value) }
                    // Clients declare no sampling/elicitation capabilities; reject server requests.
                    if let value = JSONValue.parse(payload), let remoteID = value["id"], value["method"] != nil {
                        try await rejectServerRequest(remoteID)
                    }
                }
            }
            throw MCPError.protocolError
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw MCPError.oversized }
            data.append(byte)
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), value["id"]?.doubleValue == Double(id) else { throw MCPError.protocolError }
        return try result(value)
    }

    private func rejectServerRequest(_ id: JSONValue) async throws {
        var request = request()
        request.httpBody = try JSONEncoder().encode(JSONValue.object(["jsonrpc": "2.0", "id": id,
            "error": ["code": -32601, "message": "Client capability not supported"]]))
        _ = try await session.data(for: request)
    }
    private func result(_ value: JSONValue) throws -> JSONValue {
        if value["error"] != nil { throw MCPError.serverError }
        guard let result = value["result"] else { throw MCPError.protocolError }
        return result
    }
}
