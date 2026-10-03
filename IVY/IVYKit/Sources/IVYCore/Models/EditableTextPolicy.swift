import Foundation

/// Accessibility roles alone aren't sufficient: even a text area can be read-only.
/// Passwords and static text never qualify, even if an app advertises a writable attribute.
public enum EditableTextPolicy {
    public static func permits(role: String?, secure: Bool, editable: Bool?, enabled: Bool?,
                               selectedTextSettable: Bool, valueSettable: Bool) -> Bool {
        guard let role, ["AXTextField", "AXTextArea", "AXComboBox"].contains(role),
              !secure, editable != false, enabled != false else { return false }
        return selectedTextSettable || valueSettable
    }
    public static func replacement(in value: String, location: Int, length: Int, original: String, with text: String) -> String? {
        guard location >= 0, length > 0, location <= value.utf16.count, length <= value.utf16.count - location,
              (value as NSString).substring(with: NSRange(location: location, length: length)) == original else { return nil }
        return (value as NSString).replacingCharacters(in: NSRange(location: location, length: length), with: text)
    }
}
