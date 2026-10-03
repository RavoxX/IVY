import Foundation

/// Parses raw model output into visible text and structured tool calls.
///
/// Qwen3 (via its Hugging Face chat template) emits tool calls as:
///
///     <tool_call>
///     {"name": "music_play", "arguments": {"query": "Billie Jean"}}
///     </tool_call>
///
/// Small models are not always perfectly formatted, so the parser also tolerates a
/// missing closing tag, code fences, and a bare JSON object as the whole reply.
public enum ToolCallParser {
    public struct Output: Equatable, Sendable {
        public var text: String
        public var toolCalls: [ToolCall]
        public var providerResponse: ProviderResponse?

        public init(text: String, toolCalls: [ToolCall], providerResponse: ProviderResponse? = nil) {
            self.text = text
            self.toolCalls = toolCalls
            self.providerResponse = providerResponse
        }
    }

    public static func parse(_ raw: String) -> Output {
        var text = stripThinking(raw)
        var calls: [ToolCall] = []

        while let open = text.range(of: "<tool_call>") {
            let afterOpen = text[open.upperBound...]
            let close = afterOpen.range(of: "</tool_call>")
            let body = close.map { String(afterOpen[..<$0.lowerBound]) } ?? String(afterOpen)
            if let call = decodeCall(body) { calls.append(call) }
            let removeEnd = close?.upperBound ?? text.endIndex
            text.removeSubrange(open.lowerBound..<removeEnd)
        }

        // Some generations emit only a JSON object without tags.
        if calls.isEmpty {
            let trimmed = stripFences(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"), trimmed.hasSuffix("}"), let call = decodeCall(trimmed) {
                calls.append(call)
                text = ""
            }
        }

        return Output(text: cleanVisibleText(text), toolCalls: calls)
    }

    /// True when a streaming prefix looks like the start of a tool call, so the UI should
    /// not display it as answer text.
    public static func looksLikeToolCallPrefix(_ partial: String) -> Bool {
        let trimmed = stripThinking(partial).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("```") { return true }
        let tag = "<tool_call>"
        if trimmed.hasPrefix("<") {
            return tag.hasPrefix(trimmed) || trimmed.hasPrefix(tag) || trimmed.hasPrefix("<think")
        }
        return false
    }

    public static func stripThinking(_ raw: String) -> String {
        var text = raw
        while let open = text.range(of: "<think>") {
            if let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                // Unterminated thinking block: everything after it is reasoning.
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }
        // A stray closing tag (template already opened the block).
        if let close = text.range(of: "</think>") {
            text.removeSubrange(text.startIndex..<close.upperBound)
        }
        return text
    }

    static func decodeCall(_ body: String) -> ToolCall? {
        let json = stripFences(body).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}") else { return nil }
        guard let value = JSONValue.parse(String(json[start...end])), let object = value.objectValue else {
            return nil
        }
        // Accept {"name":..,"arguments":..} and OpenAI's {"function":{"name":..,"arguments":..}}.
        let container = object["function"]?.objectValue ?? object
        guard let name = container["name"]?.stringValue, !name.isEmpty else { return nil }
        var arguments: [String: JSONValue] = [:]
        switch container["arguments"] ?? container["parameters"] {
        case .object(let dict)?: arguments = dict
        case .string(let string)?: arguments = JSONValue.parse(string)?.objectValue ?? [:]
        default: break
        }
        return ToolCall(name: name, arguments: arguments)
    }

    static func stripFences(_ text: String) -> String {
        text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
    }

    static func cleanVisibleText(_ text: String) -> String {
        text.replacingOccurrences(of: "</tool_call>", with: "")
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
