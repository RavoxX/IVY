import Foundation

/// Accumulates native tool blocks until the stream is complete. Only text deltas
/// are previewed; no partial arguments can leave this decoder as a ToolCall.
struct CloudStreamDecoder {
    let provider: AIProvider
    private(set) var value: JSONValue?
    private var claudeBlocks: [Int: [String: JSONValue]] = [:]
    private var claudeInputs: [Int: String] = [:]
    private var claudeStopped = Set<Int>()
    private var claudeMessage: [String: JSONValue] = [:]
    private var geminiParts: [JSONValue] = []
    private var geminiCandidate: [String: JSONValue] = [:]
    private var geminiRoot: [String: JSONValue] = [:]
    private var completed = false
    private var characters = 0

    mutating func receive(_ event: JSONValue, onText: @Sendable (String) -> Void) throws {
        characters += event.jsonString().utf8.count
        guard characters <= 10_000_000 else { throw CloudModelError.invalidResponse }
        switch provider {
        case .openAI:
            switch event["type"]?.stringValue {
            case "response.output_text.delta": if let delta = event["delta"]?.stringValue { onText(delta) }
            case "response.completed", "response.incomplete", "response.failed":
                value = event["response"]; completed = true
            case "error": throw CloudModelError.invalidResponse
            default: break
            }
        case .claude:
            switch event["type"]?.stringValue {
            case "message_start": claudeMessage = event["message"]?.objectValue ?? [:]
            case "content_block_start":
                guard let number = event["index"]?.doubleValue, let index = Int(exactly: number), (0..<200).contains(index),
                      let block = event["content_block"]?.objectValue else { throw CloudModelError.invalidResponse }
                claudeBlocks[Int(index)] = block
            case "content_block_delta":
                guard let number = event["index"]?.doubleValue, let index = Int(exactly: number), (0..<200).contains(index), !claudeStopped.contains(index),
                      let delta = event["delta"], var block = claudeBlocks[Int(index)] else { throw CloudModelError.invalidResponse }
                switch delta["type"]?.stringValue {
                case "text_delta":
                    let text = delta["text"]?.stringValue ?? ""; onText(text)
                    block["text"] = .string((block["text"]?.stringValue ?? "") + text)
                case "thinking_delta":
                    block["thinking"] = .string((block["thinking"]?.stringValue ?? "") + (delta["thinking"]?.stringValue ?? ""))
                case "signature_delta":
                    block["signature"] = .string((block["signature"]?.stringValue ?? "") + (delta["signature"]?.stringValue ?? ""))
                case "input_json_delta":
                    claudeInputs[Int(index), default: ""] += delta["partial_json"]?.stringValue ?? ""
                default: break
                }
                claudeBlocks[Int(index)] = block
            case "content_block_stop":
                guard let number = event["index"]?.doubleValue, let index = Int(exactly: number), (0..<200).contains(index), claudeBlocks[index] != nil else { throw CloudModelError.invalidResponse }
                if let input = claudeInputs[index] {
                    guard let parsed = JSONValue.parse(input), parsed.objectValue != nil else { throw CloudModelError.invalidResponse }
                    claudeBlocks[index]?["input"] = parsed
                }
                claudeStopped.insert(index)
            case "message_delta":
                for (key, field) in event["delta"]?.objectValue ?? [:] { claudeMessage[key] = field }
                var usage = claudeMessage["usage"]?.objectValue ?? [:]
                for (key, field) in event["usage"]?.objectValue ?? [:] { usage[key] = field }
                claudeMessage["usage"] = .object(usage)
            case "message_stop":
                guard claudeBlocks.keys.allSatisfy({ claudeStopped.contains($0) }) else { throw CloudModelError.incompleteResponse }
                claudeMessage["content"] = .array(claudeBlocks.keys.sorted().compactMap { claudeBlocks[$0].map(JSONValue.object) })
                value = .object(claudeMessage); completed = true
            case "error": throw CloudModelError.invalidResponse
            default: break
            }
        case .gemini:
            for (key, field) in event.objectValue ?? [:] where key != "candidates" { geminiRoot[key] = field }
            if let candidate = event["candidates"]?.arrayValue?.first {
                for (key, field) in candidate.objectValue ?? [:] where key != "content" { geminiCandidate[key] = field }
                let parts = candidate["content"]?["parts"]?.arrayValue ?? []
                geminiParts += parts
                for part in parts where part["thought"]?.boolValue != true {
                    if let text = part["text"]?.stringValue { onText(text) }
                }
                if candidate["finishReason"] != nil { completed = true }
            }
        case .local: throw CloudModelError.invalidResponse
        }
    }

    mutating func finish() throws -> JSONValue {
        guard completed else { throw CloudModelError.incompleteResponse }
        if provider == .gemini {
            geminiCandidate["content"] = ["role": "model", "parts": .array(geminiParts)]
            geminiRoot["candidates"] = [.object(geminiCandidate)]
            value = .object(geminiRoot)
        }
        guard let value else { throw CloudModelError.invalidResponse }
        return value
    }
}
