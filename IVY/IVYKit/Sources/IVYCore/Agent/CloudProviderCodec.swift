import Foundation

/// Provider wire formats are isolated from the agent's validation and security policy.
enum CloudProviderCodec {
    static func request(_ config: CloudModelConfiguration, messages: [ChatMessage], tools: [JSONValue],
                        options: GenerationOptions) throws -> URLRequest {
        if let error = config.validationError { throw error }
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n")
            + "\nUse the API's native function calls for actions. Never write tool calls as text or <tool_call> tags."
        let functions = tools.compactMap { $0["function"]?.objectValue }
        var pending: [ToolCall] = []
        var geminiIDs: Set<String> = []
        var turns: [JSONValue] = []
        for message in messages where message.role != .system {
            let native = message.providerResponse.flatMap {
                $0.provider == config.provider && $0.model == config.model ? $0.blocks : nil
            }
            if message.role == .tool {
                guard !pending.isEmpty else {
                    // A writer can receive tool data without its original native assistant turn.
                    appendTurn(role: "user", blocks: [textBlock("Tool result (\(message.toolName ?? "tool")): \(message.content)",
                                                              provider: config.provider)],
                               provider: config.provider, to: &turns)
                    continue
                }
                let call = pending.removeFirst()
                switch config.provider {
                case .openAI:
                    turns.append(["type": "function_call_output", "call_id": .string(call.id), "output": .string(message.content)])
                case .claude:
                    appendTurn(role: "user", blocks: [["type": "tool_result", "tool_use_id": .string(call.id),
                                                       "content": .string(message.content)]], provider: .claude, to: &turns)
                case .gemini:
                    var result: [String: JSONValue] = ["name": .string(call.name),
                                                       "response": ["result": .string(message.content)]]
                    if geminiIDs.contains(call.id) { result["id"] = .string(call.id) }
                    appendTurn(role: "user", blocks: [["functionResponse": .object(result)]],
                               provider: .gemini, to: &turns)
                case .local: break
                }
                continue
            }
            if message.role == .assistant {
                pending = message.toolCalls
                // Older Gemini models omit call IDs; don't invent an ID in their functionResponse.
                geminiIDs = Set(native?.compactMap { $0["functionCall"]?["id"]?.stringValue }
                                ?? message.toolCalls.map(\.id))
            }
            if config.provider == .openAI {
                if let native { turns += native }
                else {
                    if !message.content.isEmpty {
                        turns.append(["role": .string(message.role.rawValue), "content": .string(message.content)])
                    }
                    turns += message.toolCalls.map {
                        ["type": "function_call", "call_id": .string($0.id), "name": .string($0.name),
                         "arguments": .string(JSONValue.object($0.arguments).jsonString())]
                    }
                }
            } else {
                var blocks = native ?? []
                if native == nil {
                    if !message.content.isEmpty { blocks.append(textBlock(message.content, provider: config.provider)) }
                    blocks += message.toolCalls.map { call in
                        if config.provider == .claude {
                            return ["type": "tool_use", "id": .string(call.id), "name": .string(call.name),
                                    "input": .object(call.arguments)]
                        }
                        return ["functionCall": ["id": .string(call.id), "name": .string(call.name), "args": .object(call.arguments)]]
                    }
                }
                if !blocks.isEmpty {
                    let role = message.role == .assistant ? (config.provider == .gemini ? "model" : "assistant") : "user"
                    appendTurn(role: role, blocks: blocks, provider: config.provider, to: &turns)
                }
            }
        }

        var body: [String: JSONValue]
        let url: URL
        // Cloud reasoning shares the output budget; leave room for signatures/reasoning and tool arguments.
        let maxTokens = max(2048, options.maxTokens)
        switch config.provider {
        case .openAI:
            url = URL(string: "https://api.openai.com/v1/responses")!
            body = ["model": .string(config.model), "instructions": .string(system), "input": .array(turns),
                    "max_output_tokens": .number(Double(maxTokens)), "store": false,
                    "include": ["reasoning.encrypted_content"]]
            if !functions.isEmpty {
                body["tools"] = .array(functions.map { function in
                    var result = function
                    result["type"] = "function"
                    result["strict"] = false // Existing IVY tools have optional arguments.
                    return .object(result)
                })
            }
        case .claude:
            url = URL(string: "https://api.anthropic.com/v1/messages")!
            body = ["model": .string(config.model), "system": .string(system), "messages": .array(turns),
                    "max_tokens": .number(Double(maxTokens))]
            if !functions.isEmpty {
                body["tools"] = .array(functions.map {
                    ["name": $0["name"] ?? .null, "description": $0["description"] ?? "",
                     "input_schema": $0["parameters"] ?? ["type": "object", "properties": [:]]]
                })
            }
        case .gemini:
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(config.model):generateContent")!
            body = ["systemInstruction": ["parts": [["text": .string(system)]]], "contents": .array(turns),
                    "generationConfig": ["maxOutputTokens": .number(Double(maxTokens))]]
            if !functions.isEmpty {
                body["tools"] = [["functionDeclarations": .array(functions.map { function in
                    var declaration = function
                    declaration["parametersJsonSchema"] = declaration.removeValue(forKey: "parameters")
                    return .object(declaration)
                })]]
            }
        case .local: throw CloudModelError.invalidModel
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch config.provider {
        case .openAI: request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        case .claude:
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini: request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .local: break
        }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        return request
    }

    static func response(_ value: JSONValue, configuration config: CloudModelConfiguration) throws -> ToolCallParser.Output {
        var text = ""
        var calls: [ToolCall] = []
        let blocks: [JSONValue]
        switch config.provider {
        case .openAI:
            guard value["status"]?.stringValue == "completed" else { throw CloudModelError.incompleteResponse }
            guard let output = value["output"]?.arrayValue else { throw CloudModelError.invalidResponse }
            blocks = output
            for item in output {
                switch item["type"]?.stringValue {
                case "message":
                    for part in item["content"]?.arrayValue ?? [] {
                        if part["type"]?.stringValue == "refusal" { throw CloudModelError.blockedResponse }
                        if part["type"]?.stringValue == "output_text" { text += part["text"]?.stringValue ?? "" }
                    }
                case "function_call":
                    guard let arguments = item["arguments"]?.stringValue.flatMap(JSONValue.parse)?.objectValue else {
                        throw CloudModelError.invalidResponse
                    }
                    calls.append(try call(id: item["call_id"]?.stringValue, name: item["name"]?.stringValue, arguments: arguments))
                default: break // Reasoning blocks are replayed, never displayed.
                }
            }
        case .claude:
            if value["stop_reason"]?.stringValue == "max_tokens" { throw CloudModelError.incompleteResponse }
            if value["stop_reason"]?.stringValue == "refusal" { throw CloudModelError.blockedResponse }
            guard let content = value["content"]?.arrayValue else { throw CloudModelError.invalidResponse }
            blocks = content
            for part in content {
                if part["type"]?.stringValue == "text" { text += part["text"]?.stringValue ?? "" }
                if part["type"]?.stringValue == "tool_use" {
                    guard let arguments = part["input"]?.objectValue else { throw CloudModelError.invalidResponse }
                    calls.append(try call(id: part["id"]?.stringValue, name: part["name"]?.stringValue, arguments: arguments))
                }
            }
        case .gemini:
            guard let candidate = value["candidates"]?.arrayValue?.first else {
                if value["promptFeedback"]?["blockReason"] != nil { throw CloudModelError.blockedResponse }
                throw CloudModelError.invalidResponse
            }
            let finish = candidate["finishReason"]?.stringValue
            if finish == "MAX_TOKENS" { throw CloudModelError.incompleteResponse }
            guard finish == "STOP" else { throw CloudModelError.blockedResponse }
            guard let parts = candidate["content"]?["parts"]?.arrayValue else { throw CloudModelError.invalidResponse }
            blocks = parts // Preserve thoughtSignature exactly for Gemini tool continuations.
            for part in parts {
                if part["thought"]?.boolValue != true { text += part["text"]?.stringValue ?? "" }
                if let function = part["functionCall"] {
                    guard let arguments = function["args"]?.objectValue else { throw CloudModelError.invalidResponse }
                    calls.append(try call(id: function["id"]?.stringValue ?? UUID().uuidString,
                                          name: function["name"]?.stringValue, arguments: arguments))
                }
            }
        case .local: throw CloudModelError.invalidResponse
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !calls.isEmpty else {
            throw CloudModelError.invalidResponse
        }
        return .init(text: text.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: calls,
                     providerResponse: .init(provider: config.provider, model: config.model, blocks: blocks))
    }

    private static func call(id: String?, name: String?, arguments: [String: JSONValue]) throws -> ToolCall {
        guard let id, !id.isEmpty, let name, !name.isEmpty else { throw CloudModelError.invalidResponse }
        return ToolCall(id: id, name: name, arguments: arguments)
    }

    private static func textBlock(_ text: String, provider: AIProvider) -> JSONValue {
        provider == .claude ? ["type": "text", "text": .string(text)] : ["text": .string(text)]
    }

    /// Claude requires all parallel tool results in one user message. Gemini also groups parts by turn.
    private static func appendTurn(role: String, blocks: [JSONValue], provider: AIProvider, to turns: inout [JSONValue]) {
        let field = provider == .gemini ? "parts" : "content"
        if let last = turns.last, last["role"]?.stringValue == role, var object = last.objectValue {
            object[field] = .array((last[field]?.arrayValue ?? []) + blocks)
            turns[turns.count - 1] = .object(object)
        } else {
            turns.append(.object(["role": .string(role), field: .array(blocks)]))
        }
    }
}
