import AppKit
import IVYCore

/// Word exposes its document canvas as AXLayoutArea, rather than an editable AX
/// text field. Use Word's scripting dictionary for explicit writing requests.
/// Scripts are fixed; document text and model output travel only as event data.
@MainActor
final class WordSelectionSnapshot: WritingSelection {
    static let bundleID = "com.microsoft.Word"
    let applicationName = "Microsoft Word"
    var original: String { state.original }
    private let pid: pid_t
    private let state: WordWritingSelection
    private let descriptor: NSAppleEventDescriptor

    private init(pid: pid_t, state: WordWritingSelection, descriptor: NSAppleEventDescriptor) {
        self.pid = pid; self.state = state; self.descriptor = descriptor
    }

    static func capture(application: NSRunningApplication) async throws -> WordSelectionSnapshot {
        guard application.bundleIdentifier == bundleID, !application.isTerminated else {
            throw ToolError.unavailable("Select text in an open Word document first.")
        }
        let result = try await run(handler: "captureselection", arguments: [])
        guard result.numberOfItems == 5,
              let document = result.atIndex(1)?.stringValue, let fullValue = result.atIndex(2)?.stringValue,
              let original = result.atIndex(3)?.stringValue,
              let start = result.atIndex(4), let end = result.atIndex(5),
              let state = WordWritingSelection(documentName: document, fullValue: fullValue, original: original,
                  start: Int(start.int32Value), end: Int(end.int32Value)) else {
            throw ToolError.unavailable("Select up to 12,000 characters of regular text in the Word document body. Tables and other document areas aren't supported.")
        }
        return WordSelectionSnapshot(pid: application.processIdentifier, state: state, descriptor: result)
    }

    func replace(with text: String) async throws -> any WritingReplacement {
        try Self.checkProcess(pid)
        guard let replacement = state.replacement(text) else { throw ToolError.failed("The rewrite is empty or too long.") }
        let result = try await Self.run(handler: "replaceselection", arguments: [descriptor,
            NSAppleEventDescriptor(string: replacement.text)])
        guard result.stringValue == replacement.fullValue else {
            throw ToolError.failed("Word didn't confirm the replacement. Check the document before trying again.")
        }
        return WordTextReplacement(pid: pid, state: state, descriptor: descriptor, text: replacement.text, after: replacement.fullValue)
    }

    fileprivate static func checkProcess(_ pid: pid_t) throws {
        guard let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == bundleID, !app.isTerminated else {
            throw ToolError.failed("The original Word session closed. Select the text again.")
        }
    }

    fileprivate static func run(handler: String, arguments: [NSAppleEventDescriptor]) async throws -> NSAppleEventDescriptor {
        do { return try await AppleScriptRunner.shared.run(script, handler: handler, arguments: arguments) }
        catch let error as AppleScriptRunner.ScriptError where error.isPermissionDenied {
            throw ToolError.permissionDenied("Automation for Microsoft Word (System Settings ▸ Privacy & Security ▸ Automation ▸ IVY)")
        }
    }

    fileprivate static let script = """
        on checkedDocument()
            tell application id "com.microsoft.Word"
                if (count of documents) is 0 then error "Open a Word document and select text first."
                set doc to active document
                if read only of doc or protection type of doc is not no document protection then error "IVY doesn't rewrite read-only or protected Word documents."
                return doc
            end tell
        end checkedDocument

        on captureSelection()
            set doc to my checkedDocument()
            tell application id "com.microsoft.Word"
                set chosen to selection
                if story type of chosen is not main text story or selection type of chosen is not selection normal then error "Select regular text in the Word document body first."
                if (count of tables of chosen) > 0 then error "IVY doesn't rewrite selections containing Word tables. Select regular text in the document body."
                return {full name of doc, content of text object of doc, content of text object of chosen, selection start of chosen, selection end of chosen}
            end tell
        end captureSelection

        on replaceSelection(previousState, newText)
            set currentState to my captureSelection()
            if currentState is not equal to previousState then error "The Word document or selection changed. Select the text again before accepting."
            set doc to my checkedDocument()
            tell application id "com.microsoft.Word"
                if full name of doc is not equal to item 1 of previousState or content of text object of doc is not equal to item 2 of previousState then error "The Word document changed. Select the text again before accepting."
                set targetRange to create range doc start (item 4 of previousState) end (item 5 of previousState)
                if content of targetRange is not equal to item 3 of previousState then error "The Word text changed. Select it again before accepting."
                set content of targetRange to newText
                return content of text object of doc
            end tell
        end replaceSelection

        on restoreText(previousState, expectedValue, replacementText, replacementLength)
            set doc to my checkedDocument()
            tell application id "com.microsoft.Word"
                if full name of doc is not equal to item 1 of previousState or content of text object of doc is not equal to expectedValue then error "The Word document changed after the rewrite; undo was stopped."
                set startPosition to item 4 of previousState
                set targetRange to create range doc start startPosition end (startPosition + replacementLength)
                if content of targetRange is not equal to replacementText then error "The rewritten Word text changed; undo was stopped."
                set content of targetRange to item 3 of previousState
                return content of text object of doc
            end tell
        end restoreText
        """
}

@MainActor
private final class WordTextReplacement: WritingReplacement {
    let pid: pid_t
    let state: WordWritingSelection
    let descriptor: NSAppleEventDescriptor
    let text: String
    let after: String

    init(pid: pid_t, state: WordWritingSelection, descriptor: NSAppleEventDescriptor, text: String, after: String) {
        self.pid = pid; self.state = state; self.descriptor = descriptor; self.text = text; self.after = after
    }

    func undo() async throws -> String {
        try WordSelectionSnapshot.checkProcess(pid)
        let result = try await WordSelectionSnapshot.run(handler: "restoretext", arguments: [descriptor,
            NSAppleEventDescriptor(string: after), NSAppleEventDescriptor(string: text),
            NSAppleEventDescriptor(int32: Int32(text.utf16.count))])
        guard result.stringValue == state.fullValue else { throw ToolError.failed("Word didn't confirm restoring the original text.") }
        return "Restored the text before IVY's rewrite."
    }
}
