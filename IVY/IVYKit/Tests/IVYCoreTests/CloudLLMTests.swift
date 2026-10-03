import Foundation
import Testing
@testable import IVYCore

/// All requests in this suite use URLProtocol fixtures; no API keys or network are needed.
private final class CloudURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, JSONValue)?)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let (status, body) = try Self.handler?(request) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder().encode(body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite("Cloud AI providers", .serialized)
struct CloudLLMTests {
    private func config(_ provider: AIProvider) -> CloudModelConfiguration {
        .init(provider: provider, model: provider.defaultModel, apiKey: "test-secret")
    }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func body(_ request: URLRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
    }
    private func store() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "IVY.CloudTests.\(UUID())")!)
    }
    private let schema: JSONValue = ["type": "function", "function": ["name": "lookup", "description": "Read data",
        "parameters": ["type": "object", "properties": ["value": ["type": "string"]], "required": ["value"]]]]

    @Test("Each provider uses its native endpoint, authentication and schema")
    func wireContracts() throws {
        for provider in [AIProvider.openAI, .claude, .gemini] {
            let request = try CloudProviderCodec.request(config(provider), messages: [.system("Rules"), .user("Question")],
                                                        tools: [schema], options: .init())
            let value = try body(request)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.scheme == "https")
            #expect(request.url?.query == nil)
            #expect(!value.jsonString().contains("test-secret"))
            switch provider {
            case .openAI:
                #expect(request.url?.host == "api.openai.com")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
                #expect(value["store"] == false)
                #expect(value["tools"]?.arrayValue?.first?["name"] == "lookup")
                #expect(value["tools"]?.arrayValue?.first?["strict"] == false)
            case .claude:
                #expect(request.url?.host == "api.anthropic.com")
                #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-secret")
                #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
                #expect(value["tools"]?.arrayValue?.first?["input_schema"] == schema["function"]?["parameters"])
            case .gemini:
                #expect(request.url?.host == "generativelanguage.googleapis.com")
                #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-secret")
                #expect(value["tools"]?.arrayValue?.first?["functionDeclarations"]?.arrayValue?.first == schema["function"])
            case .local: break
            }
        }
    }

    @Test("Parallel native calls retain IDs, signatures and all tool results")
    func toolContinuations() throws {
        for provider in [AIProvider.openAI, .claude, .gemini] {
            let value: JSONValue
            switch provider {
            case .openAI:
                value = ["status": "completed", "output": [
                    ["type": "reasoning", "id": "rs_1", "encrypted_content": "encrypted", "summary": []],
                    ["type": "function_call", "call_id": "call_a", "name": "lookup", "arguments": "{\"value\":\"a\"}"],
                    ["type": "function_call", "call_id": "call_b", "name": "lookup", "arguments": "{\"value\":\"b\"}"]]]
            case .claude:
                value = ["stop_reason": "tool_use", "content": [
                    ["type": "tool_use", "id": "call_a", "name": "lookup", "input": ["value": "a"]],
                    ["type": "tool_use", "id": "call_b", "name": "lookup", "input": ["value": "b"]]]]
            case .gemini:
                value = ["candidates": [["finishReason": "STOP", "content": ["parts": [
                    ["thoughtSignature": "signature", "functionCall": ["id": "call_a", "name": "lookup", "args": ["value": "a"]]],
                    ["functionCall": ["id": "call_b", "name": "lookup", "args": ["value": "b"]]]]]]]]
            case .local: continue
            }
            let parsed = try CloudProviderCodec.response(value, configuration: config(provider))
            #expect(parsed.toolCalls.map(\.id) == ["call_a", "call_b"])
            let messages: [ChatMessage] = [.user("Look up both"),
                .assistant(parsed.text, toolCalls: parsed.toolCalls, providerResponse: parsed.providerResponse),
                .tool("lookup", "Result A"), .tool("lookup", "Result B")]
            let request = try CloudProviderCodec.request(config(provider), messages: messages, tools: [schema], options: .init())
            let payload = try body(request)
            switch provider {
            case .openAI:
                let input = try #require(payload["input"]?.arrayValue)
                #expect(input[1]["encrypted_content"] == "encrypted")
                #expect(input.suffix(2).map { $0["call_id"] } == ["call_a", "call_b"])
                #expect(input.last?["output"] == "Result B")
            case .claude:
                let results = try #require(payload["messages"]?.arrayValue?.last?["content"]?.arrayValue)
                #expect(results.count == 2)
                #expect(results.map { $0["tool_use_id"] } == ["call_a", "call_b"])
            case .gemini:
                let contents = try #require(payload["contents"]?.arrayValue)
                #expect(contents[1]["parts"]?.arrayValue?.first?["thoughtSignature"] == "signature")
                #expect(contents.last?["parts"]?.arrayValue?.map { $0["functionResponse"]?["id"] } == ["call_a", "call_b"])
            case .local: break
            }
        }
    }

    @Test("Gemini models without native call IDs receive results without invented IDs")
    func geminiWithoutIDs() throws {
        let parsed = try CloudProviderCodec.response(["candidates": [["finishReason": "STOP", "content": ["parts": [
            ["functionCall": ["name": "lookup", "args": ["value": "a"]]]]]]]], configuration: config(.gemini))
        let request = try CloudProviderCodec.request(config(.gemini), messages: [.user("Look up"),
            .assistant(parsed.text, toolCalls: parsed.toolCalls, providerResponse: parsed.providerResponse),
            .tool("lookup", "Verified")], tools: [schema], options: .init())
        let value = try body(request)
        let result = try #require(value["contents"]?.arrayValue?.last?["parts"]?.arrayValue?.first?["functionResponse"])
        #expect(result["name"] == "lookup")
        #expect(result["id"] == nil)
    }

    @Test("Text resembling a local tool call never becomes a cloud action")
    func textIsNotATool() throws {
        let text = #"<tool_call>{"name":"move_to_trash","arguments":{}}</tool_call>"#
        let parsed = try CloudProviderCodec.response(["stop_reason": "end_turn", "content": [["type": "text", "text": .string(text)]]],
                                                     configuration: config(.claude))
        #expect(parsed.text == text)
        #expect(parsed.toolCalls.isEmpty)
    }

    @Test("Truncated, blocked and malformed calls fail before executing")
    func invalidResponses() throws {
        #expect(throws: CloudModelError.incompleteResponse) {
            try CloudProviderCodec.response(["status": "incomplete", "output": []], configuration: config(.openAI))
        }
        #expect(throws: CloudModelError.incompleteResponse) {
            try CloudProviderCodec.response(["stop_reason": "max_tokens", "content": []], configuration: config(.claude))
        }
        #expect(throws: CloudModelError.blockedResponse) {
            try CloudProviderCodec.response(["promptFeedback": ["blockReason": "SAFETY"]], configuration: config(.gemini))
        }
        #expect(throws: CloudModelError.invalidResponse) {
            try CloudProviderCodec.response(["status": "completed", "output": [["type": "function_call", "name": "lookup",
                "call_id": "call_a", "arguments": "{broken"]]], configuration: config(.openAI))
        }
    }

    @Test("Defaults remain local, model preferences persist, and requests pin the provider")
    func selection() async throws {
        let settings = store()
        let local = FakeLLM(responses: ["Local answer"])
        let selected = ConfiguredLLMService(local: local, settings: settings, session: session()) { _ in "" }
        #expect(settings.aiProvider == .local)
        #expect(selected.forRequest() === local)
        settings.set("chosen-model", for: .claudeModel)
        #expect(SettingsStore(defaults: settings.defaults).cloudModel(for: .claude) == "chosen-model")
        settings.set(AIProvider.claude.rawValue, for: .aiProvider)
        let pinned = selected.forRequest()
        settings.set(AIProvider.local.rawValue, for: .aiProvider)
        #expect(!pinned.isAvailable)
        #expect(!pinned.supportsWarmUp)
        await #expect(throws: CloudModelError.missingAPIKey(.claude)) { try await pinned.loadModel() }
        #expect(local.received.isEmpty)
        settings.reset()
        #expect(settings.aiProvider == .local)
        #expect(settings.cloudModel(for: .claude) == AIProvider.claude.defaultModel)
    }

    @Test("Cloud warm-up sends no request and never runs the local model")
    func noWarmUp() async {
        let settings = store()
        settings.set(AIProvider.openAI.rawValue, for: .aiProvider)
        let local = FakeLLM(responses: [])
        CloudURLProtocol.handler = { _ in Issue.record("Warm-up contacted the provider"); return nil }
        let selected = ConfiguredLLMService(local: local, settings: settings, session: session()) { _ in "test-key" }
        let agent = AgentService(llm: selected, registry: ToolRegistry(), router: CommandRouter(resolveApp: { _ in nil }),
                                 confirm: { _ in true })
        await agent.warmUp()
        #expect(local.loadCount == 0)
    }

    @Test("HTTP failures are useful and never expose the response body")
    func httpErrors() async {
        CloudURLProtocol.handler = { _ in (401, ["error": ["message": "echoed-secret-private-input"]]) }
        let service = CloudLLMService(configuration: config(.openAI), session: session())
        do {
            _ = try await service.generateResponse(messages: [.user("Hi")], tools: [], options: .init()) { _ in }
            Issue.record("Expected authentication error")
        } catch {
            #expect((error as? CloudModelError) == .http(.openAI, 401))
            #expect(!error.localizedDescription.contains("echoed-secret"))
        }
    }

    @Test("Cancelled requests stop waiting for the provider")
    func cancellation() async throws {
        let service = CloudLLMService(configuration: config(.openAI), session: session())
        var requestTask: Task<ToolCallParser.Output, Error>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            CloudURLProtocol.handler = { _ in started.resume(); return nil }
            requestTask = Task {
                try await service.generateResponse(messages: [.user("Hi")], tools: [], options: .init()) { _ in }
            }
        }
        let task = try #require(requestTask)
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }

    @Test("Cloud tool calls still require confirmation for high-risk actions")
    func confirmation() async {
        CloudURLProtocol.handler = { _ in
            (200, ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "tool_1",
                "name": "move_to_trash", "input": ["value": "file"]]]])
        }
        let tool = RecordingTool(name: "move_to_trash", risk: .high)
        let service = CloudLLMService(configuration: config(.claude), session: session())
        let agent = AgentService(llm: service, registry: ToolRegistry(tools: [tool]),
                                 router: CommandRouter(resolveApp: { _ in nil }), fastRoutingEnabled: { false },
                                 confirm: { request in
                                     #expect(request.toolName == "move_to_trash")
                                     return false
                                 })
        var finished = false
        for await event in agent.run("Move the file to Trash") {
            if case .finished = event { finished = true }
        }
        #expect(finished)
        #expect(tool.calls.isEmpty)
    }

    @Test("Cloud tool results reach a second model pass with provider metadata intact")
    func agentContinuation() async {
        let transport = session()
        let config = config(.gemini)
        let tool = RecordingTool(name: "lookup", terminal: false, summary: "Verified result")
        CloudURLProtocol.handler = { request in
            // URLSession may present POST data as an InputStream inside URLProtocol.
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            let turns = value["contents"]?.arrayValue ?? []
            if turns.count == 1 {
                return (200, ["candidates": [["finishReason": "STOP", "content": ["parts": [
                    ["thoughtSignature": "native-signature", "functionCall": ["id": "native-call", "name": "lookup",
                        "args": ["value": "requested data"]]]]]]]])
            }
            #expect(turns[1]["parts"]?.arrayValue?.first?["thoughtSignature"] == "native-signature")
            #expect(turns.last?["parts"]?.arrayValue?.first?["functionResponse"]?["id"] == "native-call")
            #expect(turns.last?["parts"]?.arrayValue?.first?["functionResponse"]?["response"]?["result"]?.stringValue?.contains("Verified result") == true)
            return (200, ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "Here is the verified result."]]]]]])
        }
        let agent = AgentService(llm: CloudLLMService(configuration: config, session: transport),
                                 registry: ToolRegistry(tools: [tool]), router: CommandRouter(resolveApp: { _ in nil }),
                                 fastRoutingEnabled: { false }, confirm: { _ in true })
        var answer = ""
        for await event in agent.run("Look up my requested data") {
            if case .finished(let outcome) = event { answer = outcome.text }
            if case .failed(let error) = event { Issue.record("Agent failed: \(error)") }
        }
        #expect(answer == "Here is the verified result.")
        #expect(tool.calls == [["value": "requested data"]])
    }

    @Test("Model IDs cannot alter request paths and empty keys cannot send requests")
    func configurationValidation() throws {
        for invalid in ["", "../models", "model?key=secret", "model/new", "model\nheader"] {
            #expect(CloudModelConfiguration(provider: .gemini, model: invalid, apiKey: "key").validationError == .invalidModel)
        }
        #expect(CloudModelConfiguration(provider: .openAI, model: "gpt-4.1", apiKey: "  ").validationError == .missingAPIKey(.openAI))
    }
}
