import Foundation
import Testing
@testable import IVYCore

private final class StreamFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var respond: ((URLRequest) throws -> (Int, [String: String], String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let (status, headers, body) = try Self.respond?(request) else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite("MCP and cloud stream transport", .serialized)
struct MCPTransportTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func body(_ request: URLRequest) throws -> JSONValue {
        if let data = request.httpBody { return try JSONDecoder().decode(JSONValue.self, from: data) }
        let stream = try #require(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test("MCP initializes, paginates tools, parses SSE, sends exact arguments and disconnects")
    func handshake() async throws {
        let jsonHeaders = ["Content-Type": "application/json", "MCP-Session-Id": "fixture-session"]
        StreamFixtureProtocol.respond = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            if request.httpMethod == "DELETE" { return (204, [:], "") }
            let value = try body(request)
            if value["method"] == "initialize" {
                return (200, jsonHeaders, JSONValue.object(["jsonrpc": "2.0", "id": value["id"]!, "result": ["protocolVersion": "2025-11-25", "capabilities": ["tools": [:]]]]).jsonString())
            }
            #expect(request.value(forHTTPHeaderField: "MCP-Session-Id") == "fixture-session")
            if value["method"] == "notifications/initialized" { return (202, [:], "") }
            if value["method"] == "tools/list" {
                let result: JSONValue = value["params"]?["cursor"] == nil
                    ? ["tools": [["name": "read", "inputSchema": ["type": "object"]]], "nextCursor": "page2"]
                    : ["tools": [["name": "draft", "inputSchema": ["type": "object"]]]]
                let response: JSONValue = ["jsonrpc": "2.0", "id": value["id"]!, "result": result]
                return (200, ["Content-Type": "text/event-stream"], ": keepalive\n\ndata: " + response.jsonString() + "\n\n")
            }
            #expect(value["method"] == "tools/call")
            #expect(value["params"]?["name"] == "draft")
            #expect(value["params"]?["arguments"]?["body"] == "review me")
            return (200, jsonHeaders, JSONValue.object(["jsonrpc": "2.0", "id": value["id"]!, "result": ["content": [["type": "text", "text": "Draft ready."]]]]).jsonString())
        }
        defer { StreamFixtureProtocol.respond = nil }
        let client = try MCPClient(endpoint: URL(string: "https://fixture.invalid/mcp")!, token: "fixture-token", session: session())
        let tools = try await client.connect()
        #expect(tools.map(\.name) == ["read", "draft"])
        let result = try await client.call(name: "draft", arguments: ["body": "review me"])
        #expect(result["content"]?.arrayValue?.first?["text"] == "Draft ready.")
        await client.disconnect()
        await #expect(throws: (any Error).self) { try await client.call(name: "draft", arguments: [:]) }
    }

    @Test("A real SSE transport streams text and retains Gemini's completed response")
    func geminiStreaming() async throws {
        StreamFixtureProtocol.respond = { request in
            #expect(request.url?.path.hasSuffix(":streamGenerateContent") == true)
            #expect(request.url?.query == "alt=sse")
            return (200, ["Content-Type": "text/event-stream"], """
            data: {"candidates":[{"content":{"parts":[{"text":"Hello "}]}}]}

            data: {"candidates":[{"content":{"parts":[{"text":"world."}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":2}}


            """)
        }
        defer { StreamFixtureProtocol.respond = nil }
        let service = CloudLLMService(configuration: .init(provider: .gemini, model: "fixture", apiKey: "fixture"), session: session())
        let output = try await service.generateResponse(messages: [.user("Hi")], tools: [], options: .init()) { _ in }
        #expect(output.text == "Hello world.")
        #expect(output.toolCalls.isEmpty)
    }
}
