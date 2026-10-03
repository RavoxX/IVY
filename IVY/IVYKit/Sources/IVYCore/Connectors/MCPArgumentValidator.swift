import Foundation

/// Checks the common JSON Schema constraints locally; the MCP server remains responsible
/// for its complete schema. Validation never changes arguments or executes data.
public enum MCPArgumentValidator {
    public static func validate(_ arguments: [String: JSONValue], schema: JSONValue) throws {
        guard JSONValue.object(arguments).jsonString().utf8.count <= 8_000 else {
            throw ToolError.invalidArgument("connector arguments", "too large to review safely")
        }
        try check(.object(arguments), schema: schema, path: "arguments", depth: 0)
    }
    private static func check(_ value: JSONValue, schema: JSONValue, path: String, depth: Int) throws {
        guard depth <= 16 else { throw ToolError.invalidArgument(path, "nested too deeply") }
        func invalid(_ reason: String) throws { throw ToolError.invalidArgument(path, reason) }
        if let choices = schema["enum"]?.arrayValue, !choices.contains(value) { try invalid("not an allowed value") }
        if let constant = schema["const"], value != constant { try invalid("doesn't match the required value") }
        if let type = schema["type"]?.stringValue {
            let matches: Bool
            switch (type, value) {
            case ("object", .object), ("array", .array), ("string", .string), ("number", .number), ("boolean", .bool), ("null", .null): matches = true
            case ("integer", .number(let number)): matches = number.isFinite && number.rounded() == number
            default: matches = false
            }
            if !matches { try invalid("expected \(type)") }
        }
        switch value {
        case .object(let object):
            for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil { try invalid("missing \(key)") }
            let properties = schema["properties"]?.objectValue ?? [:]
            for (key, child) in object {
                if let childSchema = properties[key] { try check(child, schema: childSchema, path: path + "." + key, depth: depth + 1) }
                else if schema["additionalProperties"] == false { try invalid("unexpected argument \(key)") }
            }
        case .array(let array):
            if let min = schema["minItems"]?.doubleValue, Double(array.count) < min { try invalid("too few items") }
            if let max = schema["maxItems"]?.doubleValue, Double(array.count) > max { try invalid("too many items") }
            if let itemSchema = schema["items"], itemSchema.objectValue != nil {
                for (index, item) in array.enumerated() { try check(item, schema: itemSchema, path: path + "[\(index)]", depth: depth + 1) }
            }
        case .string(let string):
            if let min = schema["minLength"]?.doubleValue, Double(string.count) < min { try invalid("too short") }
            if let max = schema["maxLength"]?.doubleValue, Double(string.count) > max { try invalid("too long") }
        case .number(let number):
            guard number.isFinite else { try invalid("not finite"); return }
            if let min = schema["minimum"]?.doubleValue, number < min { try invalid("below minimum") }
            if let max = schema["maximum"]?.doubleValue, number > max { try invalid("above maximum") }
        default: break
        }
    }
}
