import Foundation

/// Word positions refer to the main document story. Validate them against the
/// returned text before writing; tables and other stories have different offsets.
public struct WordWritingSelection: Equatable {
    public let documentName: String
    public let fullValue: String
    public let original: String
    public let location: Int
    public let length: Int

    public init?(documentName: String, fullValue: String, original: String, start: Int, end: Int) {
        guard !documentName.isEmpty, !original.isEmpty, original.count <= 12_000,
              start >= 0, end > start,
              EditableTextPolicy.replacement(in: fullValue, location: start, length: end - start,
                  original: original, with: original) != nil else { return nil }
        self.documentName = documentName; self.fullValue = fullValue; self.original = original
        self.location = start; self.length = end - start
    }

    /// Word uses carriage returns for paragraphs and requires its final paragraph
    /// mark. Model previews normally use line feeds and can omit a trailing mark.
    public func replacement(_ text: String) -> (text: String, fullValue: String)? {
        guard !text.isEmpty, text.utf16.count <= 40_000 else { return nil }
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if location + length == fullValue.utf16.count, original.hasSuffix("\r"), !normalized.hasSuffix("\r") {
            normalized += "\r"
        }
        guard let value = EditableTextPolicy.replacement(in: fullValue, location: location, length: length,
            original: original, with: normalized) else { return nil }
        return (normalized, value)
    }
}
