import AppKit
import CryptoKit
import IVYCore
import Network

/// OAuth uses a loopback redirect, a fresh state and PKCE S256. No credentials enter a URL.
@MainActor
final class ConnectorOAuth {
    struct Grant: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var clientID: String
        var clientSecret: String?
        var tokenEndpoint: URL
        var revocationEndpoint: URL?
        var resource: String
    }
    private let session = MCPRedirectGuard.session()
    private var listener: LoopbackAuthorization?
    private(set) var authorizationHost = ""

    func signIn(endpoint: URL, clientID suppliedClient: String, clientSecret: String, scope: String) async throws -> Grant {
        let resource = try await resourceMetadata(endpoint)
        guard let issuerText = resource["authorization_servers"]?.arrayValue?.first?.stringValue,
              let issuer = URL(string: issuerText), MCPURL.validate(issuer) else { throw MCPError.authentication }
        let metadata = try await authorizationMetadata(issuer)
        guard metadata["issuer"]?.stringValue?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == issuerText.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              let authURL = metadata["authorization_endpoint"]?.stringValue.flatMap(URL.init(string:)),
              let tokenURL = metadata["token_endpoint"]?.stringValue.flatMap(URL.init(string:)),
              MCPURL.validate(authURL), MCPURL.validate(tokenURL) else { throw MCPError.protocolError }
        authorizationHost = authURL.host ?? ""
        let loopback = try LoopbackAuthorization()
        listener = loopback
        defer { loopback.cancel(); listener = nil }
        let redirect = try await loopback.start()
        var client = suppliedClient.trimmingCharacters(in: .whitespacesAndNewlines)
        var secret = clientSecret.isEmpty ? nil : clientSecret
        if client.isEmpty {
            guard let registrationURL = metadata["registration_endpoint"]?.stringValue.flatMap(URL.init(string:)),
                  MCPURL.validate(registrationURL) else {
                throw ToolError.unavailable("This service requires an OAuth client ID. Follow its setup link, create a Desktop/native client, and enter the ID in Advanced authentication.")
            }
            let registration = try await jsonRequest(registrationURL, body: ["client_name": "IVY", "redirect_uris": [.string(redirect.absoluteString)],
                "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "token_endpoint_auth_method": "none"])
            guard let registered = registration["client_id"]?.stringValue, !registered.isEmpty else { throw MCPError.authentication }
            client = registered; secret = registration["client_secret"]?.stringValue
        }
        let verifier = Self.random(); let state = Self.random()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var url = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "client_id", value: client), URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: endpoint.absoluteString)]
        let requestedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        let supported = resource["scopes_supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if !requestedScope.isEmpty { url.queryItems?.append(URLQueryItem(name: "scope", value: requestedScope)) }
        else if !supported.isEmpty { url.queryItems?.append(URLQueryItem(name: "scope", value: supported.joined(separator: " "))) }
        // Google only issues a refresh token for offline consent.
        if authURL.host == "accounts.google.com" {
            url.queryItems?.append(URLQueryItem(name: "access_type", value: "offline"))
            url.queryItems?.append(URLQueryItem(name: "prompt", value: "consent"))
        }
        let code = try await loopback.authorize(url.url!, state: state)
        var fields = ["grant_type": "authorization_code", "code": code, "client_id": client,
            "redirect_uri": redirect.absoluteString, "code_verifier": verifier, "resource": endpoint.absoluteString]
        if let secret { fields["client_secret"] = secret }
        let tokens = try await formRequest(tokenURL, fields: fields)
        return try grant(tokens, client: client, secret: secret, metadata: metadata, endpoint: endpoint)
    }

    func refresh(_ existing: Grant) async throws -> Grant {
        guard let refresh = existing.refreshToken else { throw MCPError.authentication }
        var fields = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": existing.clientID, "resource": existing.resource]
        if let secret = existing.clientSecret { fields["client_secret"] = secret }
        let value = try await formRequest(existing.tokenEndpoint, fields: fields)
        guard let token = value["access_token"]?.stringValue, !token.isEmpty else { throw MCPError.authentication }
        var updated = existing; updated.accessToken = token
        updated.refreshToken = value["refresh_token"]?.stringValue ?? refresh
        updated.expiresAt = value["expires_in"]?.doubleValue.map { Date().addingTimeInterval($0) }
        return updated
    }
    func revoke(_ grant: Grant) async throws {
        guard let url = grant.revocationEndpoint else { throw ToolError.unavailable("This service doesn't offer automatic revocation. Remove IVY in the service's authorized apps page.") }
        _ = try await formRequest(url, fields: ["token": grant.refreshToken ?? grant.accessToken, "client_id": grant.clientID].merging(
            grant.clientSecret.map { ["client_secret": $0] } ?? [:], uniquingKeysWith: { _, b in b }), requireJSON: false)
    }
    func cancel() { listener?.cancel() }
    private func grant(_ tokens: JSONValue, client: String, secret: String?, metadata: JSONValue, endpoint: URL) throws -> Grant {
        guard let token = tokens["access_token"]?.stringValue, !token.isEmpty,
              tokens["token_type"]?.stringValue?.lowercased() == "bearer",
              let tokenURL = metadata["token_endpoint"]?.stringValue.flatMap(URL.init(string:)) else { throw MCPError.authentication }
        return Grant(accessToken: token, refreshToken: tokens["refresh_token"]?.stringValue,
            expiresAt: tokens["expires_in"]?.doubleValue.map { Date().addingTimeInterval($0) }, clientID: client,
            clientSecret: secret, tokenEndpoint: tokenURL,
            revocationEndpoint: metadata["revocation_endpoint"]?.stringValue.flatMap(URL.init(string:)).flatMap { MCPURL.validate($0) ? $0 : nil },
            resource: endpoint.absoluteString)
    }
    private func resourceMetadata(_ endpoint: URL) async throws -> JSONValue {
        var probe = URLRequest(url: endpoint); probe.httpMethod = "POST"; probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probe.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        probe.httpBody = Data("{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"IVY\",\"version\":\"2.0\"}}}".utf8)
        let (_, response) = try await session.data(for: probe)
        let challenge = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
        var candidates: [URL] = []
        if let range = challenge.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression) {
            let text = challenge[range].dropFirst("resource_metadata=\"".count).dropLast()
            if let url = URL(string: String(text)), MCPURL.validate(url) { candidates.append(url) }
        }
        var base = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        base.path = "/.well-known/oauth-protected-resource" + (endpoint.path == "/" ? "" : endpoint.path)
        candidates.append(base.url!)
        base.path = "/.well-known/oauth-protected-resource"; candidates.append(base.url!)
        for url in candidates {
            if let value = try? await get(url), let resource = value["resource"]?.stringValue.flatMap(URL.init(string:)),
               resource.scheme == endpoint.scheme, resource.host == endpoint.host, resource.port == endpoint.port,
               (resource.path == endpoint.path || endpoint.path.hasPrefix(resource.path.hasSuffix("/") ? resource.path : resource.path + "/")) {
                return value
            }
        }
        throw ToolError.unavailable("OAuth discovery isn't available here. Add a server-issued token, or check the service's MCP setup instructions.")
    }
    private func authorizationMetadata(_ issuer: URL) async throws -> JSONValue {
        var base = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
        let path = base.path == "/" ? "" : base.path
        let paths = ["/.well-known/oauth-authorization-server" + path, "/.well-known/openid-configuration" + path, path + "/.well-known/openid-configuration"]
        for path in paths {
            base.path = path
            if let value = try? await get(base.url!), value["authorization_endpoint"] != nil { return value }
        }
        throw MCPError.authentication
    }
    private func get(_ url: URL) async throws -> JSONValue { try await response(URLRequest(url: url)) }
    private func jsonRequest(_ url: URL, body: JSONValue) async throws -> JSONValue {
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body); return try await response(request)
    }
    private func formRequest(_ url: URL, fields: [String: String], requireJSON: Bool = true) async throws -> JSONValue {
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { "\(escape($0.key))=\(escape($0.value))" }.joined(separator: "&").utf8)
        return try await response(request, requireJSON: requireJSON)
    }
    private func response(_ request: URLRequest, requireJSON: Bool = true) async throws -> JSONValue {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw MCPError.authentication }
        guard data.count <= 1_000_000 else { throw MCPError.oversized }
        if !requireJSON { return [:] }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw MCPError.protocolError }
        return value
    }
    private static func random() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
}

/// A loopback-only listener. Unrelated browser requests cannot complete the OAuth session.
@MainActor
private final class LoopbackAuthorization {
    private let listener: NWListener
    private var ready: CheckedContinuation<URL, Error>?
    private var callback: CheckedContinuation<String, Error>?
    private var expectedState = ""
    private var timeout: Task<Void, Never>?
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener.port else { self.cancel(); return }
                        self.ready?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/callback")!); self.ready = nil
                    case .failed: self.cancel()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                Task { @MainActor [weak self] in self?.readRequest(connection, buffered: Data()) }
            }
            listener.start(queue: .main)
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }; self?.cancel()
            }
          }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    private func readRequest(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384 - buffered.count) { [weak self] data, _, completed, error in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                var collected = buffered
                if let data { collected.append(data) }
                if collected.range(of: Data("\r\n\r\n".utf8)) != nil { self.receive(collected, connection: connection) }
                else if collected.count >= 16_384 || completed || error != nil { connection.cancel() }
                else { self.readRequest(connection, buffered: collected) }
            }
        }
    }
    func authorize(_ url: URL, state: String) async throws -> String {
        expectedState = state
        timeout?.cancel()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                callback = continuation
                guard NSWorkspace.shared.open(url) else { cancel(); return }
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(180))
                    guard !Task.isCancelled else { return }
                    self?.cancel()
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    private func receive(_ data: Data?, connection: NWConnection) {
        let line = data.map { String(decoding: $0, as: UTF8.self).components(separatedBy: "\r\n").first ?? "" } ?? ""
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", let parsed = URLComponents(string: String(parts[1])), parsed.path == "/callback",
              parsed.queryItems?.first(where: { $0.name == "state" })?.value == expectedState, !expectedState.isEmpty else {
            send("Not found.", status: "404 Not Found", connection: connection); return
        }
        let code = parsed.queryItems?.first(where: { $0.name == "code" })?.value
        send(code == nil ? "Sign-in was declined. Return to IVY." : "Connected. You can close this window and return to IVY.", connection: connection)
        if let code { callback?.resume(returning: code); callback = nil }
        else { callback?.resume(throwing: MCPError.authentication); callback = nil }
        expectedState = ""; timeout?.cancel(); listener.cancel()
    }
    private func send(_ text: String, status: String = "200 OK", connection: NWConnection) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(text.utf8.count)\r\nConnection: close\r\n\r\n\(text)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
    func cancel() {
        timeout?.cancel(); listener.cancel()
        ready?.resume(throwing: CancellationError()); ready = nil
        callback?.resume(throwing: CancellationError()); callback = nil
    }
}
