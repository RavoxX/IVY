import AppKit
import ApplicationServices
import IVYCore
import PDFKit
import Vision

struct ContextAttachment: Identifiable {
    let id = UUID()
    let name: String
    let text: String
}

/// Files are read only after selection. Only the previewed text is included when Send is pressed.
enum ContextAttachmentService {
    static func read(_ url: URL) throws -> ContextAttachment {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 20_000_000 else {
            throw ToolError.unavailable("Choose a regular document or image smaller than 20 MB.")
        }
        let text: String
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url) else { throw ToolError.failed("This PDF couldn't be read.") }
            text = (0..<min(document.pageCount, 30)).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        case "png", "jpg", "jpeg", "heic", "tiff":
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(url: url).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        case "txt", "md", "csv", "json", "swift", "py", "js", "ts", "html", "xml", "log":
            text = try String(contentsOf: url, encoding: .utf8)
        default: throw ToolError.unavailable("Attach a PDF, text document, or image. Images are converted to text locally.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError.unavailable("No readable text was found in this file.") }
        return ContextAttachment(name: url.lastPathComponent, text: String(text.prefix(12_000)))
    }

    @MainActor static func selectedText(application: NSRunningApplication?) throws -> ContextAttachment {
        guard AXIsProcessTrusted(), let application else { throw ToolError.unavailable("Allow IVY in System Settings → Privacy & Security → Accessibility, then select text in another app and reopen IVY.") }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { throw ToolError.unavailable("The app doesn't expose its selected text. Copy it and use Add copied text.") }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != kAXSecureTextFieldSubrole else { throw ToolError.unavailable("IVY doesn't read password fields.") }
        var text: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &text) == .success,
              let value = text as? String, !value.isEmpty else { throw ToolError.unavailable("Select some text first, or use Add copied text.") }
        return ContextAttachment(name: "Selection from \(application.localizedName ?? "app")", text: String(value.prefix(12_000)))
    }
}
