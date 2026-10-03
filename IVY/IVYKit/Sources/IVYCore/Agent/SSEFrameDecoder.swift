import Foundation

enum SSEFrameError: LocalizedError {
    case oversized, invalidEncoding
    var errorDescription: String? {
        switch self {
        case .oversized: return "The streaming response exceeded IVY's size limit."
        case .invalidEncoding: return "The streaming response wasn't valid UTF-8."
        }
    }
}

/// AsyncBytes.lines omits empty lines, which are meaningful SSE event boundaries.
/// Parse bytes directly, handling LF, CRLF and CR, and preserve multiline data.
/// An unterminated event at EOF is discarded rather than executed.
struct SSEFrameDecoder {
    let limit: Int
    private var count = 0
    private var line = Data()
    private var data: [String] = []
    private var afterCR = false
    private var firstLine = true

    init(limit: Int) { self.limit = limit }

    mutating func receive(_ byte: UInt8) throws -> String? {
        count += 1
        guard count <= limit else { throw SSEFrameError.oversized }
        if byte == 10, afterCR { afterCR = false; return nil }
        afterCR = byte == 13
        if byte == 10 || byte == 13 { return try finishLine() }
        line.append(byte)
        return nil
    }
    private mutating func finishLine() throws -> String? {
        guard var text = String(data: line, encoding: .utf8) else { throw SSEFrameError.invalidEncoding }
        line.removeAll(keepingCapacity: true)
        if firstLine { firstLine = false; if text.hasPrefix("\u{feff}") { text.removeFirst() } }
        if text.isEmpty {
            let payload = data.joined(separator: "\n")
            data.removeAll(keepingCapacity: true)
            return payload.isEmpty ? nil : payload
        }
        if text == "data" { data.append("") }
        else if text.hasPrefix("data:") {
            var value = String(text.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            data.append(value)
        }
        return nil
    }
}
