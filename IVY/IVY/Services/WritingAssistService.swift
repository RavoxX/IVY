import AppKit
import ApplicationServices
import Combine
import IVYCore

enum WritingAction: String, CaseIterable, Identifiable {
    case improve, rephrase, shorten, professional, friendly, translate
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var instruction: String {
        switch self {
        case .improve: return "Correct grammar, spelling and punctuation and improve clarity."
        case .rephrase: return "Rephrase this text in natural, clear language."
        case .shorten: return "Shorten this text while preserving every important fact."
        case .professional: return "Rewrite this text in a professional, respectful tone."
        case .friendly: return "Rewrite this text in a warm, friendly tone."
        case .translate: return "Translate this text accurately into the requested language."
        }
    }
}

@MainActor
final class WritingAssistService: ObservableObject {
    @Published private(set) var original = ""
    @Published private(set) var suggestion = ""
    @Published private(set) var sourceName = ""
    @Published private(set) var isWorking = false
    @Published private(set) var error = ""
    @Published private(set) var applied = false
    @Published private(set) var readyToAccept = false
    @Published private(set) var isApplying = false
    @Published var action: WritingAction = .improve
    var onPresent: (() -> Void)?
    var canPresentAutomatically: (() -> Bool)?
    private let textService: LLMTextService
    private let settings: SettingsStore
    private let undo: UndoStore
    private var selection: (any WritingSelection)?
    private var captureTask: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var generationID = UUID()
    private var keyMonitor: Any?
    private var selectionTimer: Timer?
    private var selectionMonitor: Any?
    private var selectionCheck: DispatchWorkItem?
    private var selectionSettler = WritingSelectionSettler<AutomaticWritingSelectionSignature>()
    private var wordPollGate = WritingSelectionPollGate()
    private var wordPollTask: Task<Void, Never>?
    private var wordHoverCheck: DispatchWorkItem?
    private var wordIndicatorSelection: WordSelectionSnapshot?
    private var wordIndicatorAnchor: (signature: AutomaticWritingSelectionSignature, bounds: CGRect)?
    private var defaultsObserver: NSObjectProtocol?
    private let indicator = WritingSelectionIndicator()

    init(textService: LLMTextService, settings: SettingsStore, undo: UndoStore) {
        self.textService = textService; self.settings = settings; self.undo = undo
    }
    func start() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 13, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option] {
                Task { @MainActor [weak self] in self?.prepare() }
            }
        }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configureSelectionMonitor() }
        }
        configureSelectionMonitor()
    }
    func stop() {
        cancel()
        indicator.hide()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }; defaultsObserver = nil
        selectionTimer?.invalidate(); selectionTimer = nil
        if let selectionMonitor { NSEvent.removeMonitor(selectionMonitor) }; selectionMonitor = nil
    }
    private func configureSelectionMonitor() {
        selectionTimer?.invalidate(); selectionTimer = nil
        if let selectionMonitor { NSEvent.removeMonitor(selectionMonitor) }; selectionMonitor = nil
        resetAutomaticSelection()
        guard settings.bool(.writingAssistEnabled), !settings.bool(.paused) else { cancel(); return }
        guard settings.bool(.writingAssistOnSelection), AXIsProcessTrusted() else { return }
        selectionMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown, .keyUp, .flagsChanged, .scrollWheel, .mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch event.type {
                case .leftMouseDown, .leftMouseDragged, .keyDown, .scrollWheel:
                    self.resetAutomaticSelection()
                case .mouseMoved:
                    self.scheduleWordHover()
                default:
                    self.pollSelection()
                }
            }
        }
        selectionTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollSelection() }
        }
    }
    private func pollSelection() {
        guard !indicator.isHandlingClick else { return }
        selectionCheck?.cancel(); selectionCheck = nil
        // Dragging and Shift-selection can last across several polling intervals.
        // Never show an affordance until the gesture has ended.
        guard NSEvent.pressedMouseButtons & 1 == 0, !NSEvent.modifierFlags.contains(.shift) else {
            resetAutomaticSelection(); return
        }
        guard allowsAutomaticSelection, let application = NSWorkspace.shared.frontmostApplication else { resetAutomaticSelection(); return }
        if application.bundleIdentifier == WordSelectionSnapshot.bundleID {
            pollWordSelection(application: application)
            return
        }
        wordPollGate.invalidate(); wordPollTask?.cancel(); wordIndicatorAnchor = nil; wordIndicatorSelection = nil
        guard let captured = try? TextSelectionSnapshot.capture(application: application), let bounds = captured.selectionBounds else { resetAutomaticSelection(); return }
        guard selectionHasSettled(.accessibility(captured.signature)) else { return }
        indicator.show(nextTo: bounds) { [weak self] in
            guard let self, self.canPresentAutomatically?() != false, captured.isCurrent,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == captured.pid else { return }
            self.prepare(snapshot: captured)
        }
    }
    private func resetAutomaticSelection() {
        selectionCheck?.cancel(); selectionCheck = nil
        wordPollGate.invalidate(); wordPollTask?.cancel()
        wordHoverCheck?.cancel(); wordHoverCheck = nil
        wordIndicatorSelection = nil
        wordIndicatorAnchor = nil
        selectionSettler.reset()
        indicator.hide()
    }

    private var allowsAutomaticSelection: Bool {
        settings.bool(.writingAssistEnabled) && settings.bool(.writingAssistOnSelection) && !settings.bool(.paused) &&
        AXIsProcessTrusted() && !isWorking && !isApplying && captureTask == nil && canPresentAutomatically?() != false &&
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier &&
        NSEvent.pressedMouseButtons & 1 == 0 && !NSEvent.modifierFlags.contains(.shift)
    }

    private func selectionHasSettled(_ signature: AutomaticWritingSelectionSignature) -> Bool {
        guard selectionSettler.shouldShow(selection: signature, isSelecting: false, at: ProcessInfo.processInfo.systemUptime) else {
            indicator.hide()
            let check = DispatchWorkItem { [weak self] in self?.pollSelection() }
            selectionCheck = check
            DispatchQueue.main.asyncAfter(deadline: .now() + selectionSettler.delay, execute: check)
            return false
        }
        return true
    }

    private func pollWordSelection(application: NSRunningApplication) {
        guard let token = wordPollGate.begin() else { return }
        let bundleID = WordSelectionSnapshot.bundleID
        wordPollTask = Task { [weak self] in
            // Never trigger an Automation consent dialog from passive polling.
            let permission = await Task.detached(priority: .utility) {
                PermissionService.automationStatus(bundleID: bundleID)
            }.value
            var captured: WordSelectionSnapshot?
            if permission == .granted, !Task.isCancelled {
                captured = try? await WordSelectionSnapshot.capture(application: application)
            }
            guard let self else { return }
            self.wordPollTask = nil
            guard self.wordPollGate.finish(token), !Task.isCancelled else { return }
            guard !self.indicator.isHandlingClick else { return }
            guard self.allowsAutomaticSelection,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
                  let captured, let bounds = captured.selectionBounds else { self.resetAutomaticSelection(); return }
            let signature = AutomaticWritingSelectionSignature.word(application.processIdentifier, captured.signature)
            self.wordIndicatorSelection = captured
            if self.wordIndicatorAnchor?.signature != signature { self.wordIndicatorAnchor = (signature, bounds) }
            guard self.selectionHasSettled(signature), let anchor = self.wordIndicatorAnchor else { return }
            self.indicator.show(nextTo: anchor.bounds) { [weak self] in
                guard let self, self.allowsAutomaticSelection,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return }
                // A click captures again through the same Word path as the menu.
                // Only that fresh snapshot is used for preview and Accept checks.
                self.prepare(application: application)
            }
        }
    }

    /// Move only after the pointer settles over the document, so the button stays
    /// still while the user crosses the gap to click it. No Word script or model
    /// request is needed to update an already captured selection's geometry.
    private func scheduleWordHover() {
        wordHoverCheck?.cancel(); wordHoverCheck = nil
        guard wordIndicatorSelection != nil, indicator.isVisible else { return }
        let check = DispatchWorkItem { [weak self] in
            guard let self, self.allowsAutomaticSelection, !self.indicator.isHandlingClick, !self.indicator.isPointerInside,
                  self.indicator.isVisible, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == WordSelectionSnapshot.bundleID,
                  let selection = self.wordIndicatorSelection, let bounds = selection.hoverBounds(at: NSEvent.mouseLocation),
                  let anchor = self.wordIndicatorAnchor else { return }
            self.wordIndicatorAnchor = (anchor.signature, bounds)
            self.indicator.show(nextTo: bounds) { [weak self] in
                guard let self, self.allowsAutomaticSelection,
                      let application = NSWorkspace.shared.frontmostApplication,
                      application.bundleIdentifier == WordSelectionSnapshot.bundleID else { return }
                self.prepare(application: application)
            }
        }
        wordHoverCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: check)
    }
    func prepare(application: NSRunningApplication? = nil) {
        guard settings.bool(.writingAssistEnabled), !settings.bool(.paused), !isApplying else { return }
        cancel(); selection = nil; original = ""; suggestion = ""; error = ""; applied = false; sourceName = ""
        let application = application ?? NSWorkspace.shared.frontmostApplication
        if application?.bundleIdentifier == WordSelectionSnapshot.bundleID, let application {
            let id = generationID
            captureTask = Task { [weak self] in
                do {
                    let snapshot = try await WordSelectionSnapshot.capture(application: application)
                    guard let self, self.generationID == id, !Task.isCancelled else { return }
                    self.prepare(snapshot: snapshot)
                } catch {
                    guard let self, self.generationID == id, !Task.isCancelled else { return }
                    self.captureTask = nil
                    self.error = error.localizedDescription; self.onPresent?()
                }
            }
        } else {
            do { prepare(snapshot: try TextSelectionSnapshot.capture(application: application)) }
            catch { self.error = error.localizedDescription; onPresent?() }
        }
    }
    private func prepare(snapshot: any WritingSelection) {
        indicator.hide()
        cancel(); selection = snapshot; original = snapshot.original
        sourceName = snapshot.applicationName; suggestion = ""; error = ""; applied = false
        onPresent?()
    }
    var activeModelLabel: String {
        let task: AITask = action == .translate ? .translation : .grammar
        let choice = settings.modelChoice(for: task)
        return choice.provider.displayName + " · " + choice.model
    }
    var sendsToCloud: Bool { settings.modelChoice(for: action == .translate ? .translation : .grammar).provider != .local }

    func generate() {
        guard let selection, !isWorking, !isApplying else { return }
        let id = UUID(); generationID = id
        suggestion = ""; error = ""; applied = false; readyToAccept = false; isWorking = true
        let instruction = action.instruction + (action == .translate ? " Target language: " + String(settings.string(.writingLanguage).prefix(80)) + "." : " Keep the original language.")
        let rewrite = WritingRewrite(text: selection.original)
        let task: AITask = action == .translate ? .translation : .grammar
        work = Task { [self] in
            defer { if generationID == id { isWorking = false } }
            do {
                let response = try await textService.complete(system: WritingRewrite.systemPrompt,
                    user: rewrite.userPrompt(instruction: instruction), task: task, maxTokens: rewrite.maxTokens)
                guard generationID == id, !Task.isCancelled else { return }
                let result = try rewrite.result(from: response)
                suggestion = result
                if result.isEmpty { error = "The model returned no rewrite." }
                else { readyToAccept = true }
            } catch is CancellationError { }
            catch { if generationID == id { suggestion = ""; self.error = error.localizedDescription } }
        }
    }
    func accept() {
        guard readyToAccept, !isWorking, !isApplying, !suggestion.isEmpty, let selection, !applied else { return }
        isApplying = true
        let id = generationID, text = suggestion
        Task { [self] in
            defer { isApplying = false }
            do {
                let replacement = try await selection.replace(with: text)
                undo.add(label: "Restore selected text") { try await replacement.undo() }
                if generationID == id { applied = true; error = ""; original = text }
            } catch { if generationID == id { self.error = error.localizedDescription } }
        }
    }
    func cancel() { resetAutomaticSelection(); generationID = UUID(); captureTask?.cancel(); captureTask = nil; work?.cancel(); work = nil; isWorking = false; readyToAccept = false }
}

private enum AutomaticWritingSelectionSignature: Equatable {
    case accessibility(WritingSelectionSignature)
    case word(pid_t, WordWritingSelection)
}

@MainActor
protocol WritingSelection {
    var original: String { get }
    var applicationName: String { get }
    func replace(with text: String) async throws -> any WritingReplacement
}

@MainActor
protocol WritingReplacement {
    func undo() async throws -> String
}

/// Includes the accessibility element so identical selections in different fields
/// cannot reuse a previous field's debounce interval.
private struct WritingSelectionSignature: Equatable {
    let element: AXUIElement
    let pid: pid_t
    let original: String
    let location: Int
    let length: Int
    let fullValue: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && lhs.location == rhs.location && lhs.length == rhs.length &&
        lhs.original == rhs.original && lhs.fullValue == rhs.fullValue && CFEqual(lhs.element, rhs.element)
    }
}

/// Accept targets the original accessibility element, not whichever app has focus now.
/// A changed range or original value aborts the edit. No pasteboard or synthetic keystrokes.
@MainActor
private final class TextSelectionSnapshot: WritingSelection {
    let element: AXUIElement
    let pid: pid_t
    let applicationName: String
    let original: String
    let range: CFRange
    let fullValue: String?
    var signature: WritingSelectionSignature {
        WritingSelectionSignature(element: element, pid: pid, original: original, location: range.location, length: range.length, fullValue: fullValue)
    }
    init(element: AXUIElement, pid: pid_t, applicationName: String, original: String, range: CFRange, fullValue: String?) {
        self.element = element; self.pid = pid; self.applicationName = applicationName; self.original = original; self.range = range; self.fullValue = fullValue
    }
    static func capture(application: NSRunningApplication? = nil) throws -> TextSelectionSnapshot {
        guard AXIsProcessTrusted() else { throw ToolError.permissionDenied("Accessibility (required to read and replace selected text)") }
        guard let application = application ?? NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else { throw ToolError.unavailable("Select text in another app, then use ⌃⌥W or Writing Assistant in the IVY menu.") }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { throw ToolError.unavailable("This app doesn't expose an editable selection.") }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        if string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { throw ToolError.unavailable("IVY doesn't read or rewrite password fields.") }
        guard isEditable(element) else { throw ToolError.unavailable("Select text in an editable text field. IVY doesn't rewrite read-only text.") }
        guard let text = string(element, kAXSelectedTextAttribute), !text.isEmpty, text.count <= 12_000,
              let range = selectedRange(element), let value = string(element, kAXValueAttribute),
              validRange(range, value: value), (value as NSString).substring(with: NSRange(location: range.location, length: range.length)) == text else { throw ToolError.unavailable("Select up to 12,000 characters in an editable text field first.") }
        return TextSelectionSnapshot(element: element, pid: application.processIdentifier,
            applicationName: application.localizedName ?? "App", original: text, range: range, fullValue: value)
    }
    var isCurrent: Bool {
        guard Self.isEditable(element), Self.string(element, kAXValueAttribute) == fullValue,
              Self.string(element, kAXSelectedTextAttribute) == original,
              let current = Self.selectedRange(element) else { return false }
        return current.location == range.location && current.length == range.length
    }

    var selectionBounds: CGRect? {
        WritingAccessibilityBounds.selection(element: element, range: range) ?? WritingAccessibilityBounds.field(element: element)
    }

    func replace(with text: String) async throws -> any WritingReplacement {
        guard Self.isEditable(element), !text.isEmpty, text.utf16.count <= 40_000, Self.string(element, kAXSelectedTextAttribute) == original,
              let currentRange = Self.selectedRange(element), currentRange.location == range.location, currentRange.length == range.length else {
            throw ToolError.failed("The selection changed. Select the text again before accepting.")
        }
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard let previous = Self.string(element, kAXValueAttribute), previous == fullValue, Self.validRange(range, value: previous) else {
            throw ToolError.failed("The field changed. Select the text again before accepting.")
        }
        guard let expected = EditableTextPolicy.replacement(in: previous, location: range.location, length: range.length, original: original, with: text) else {
            throw ToolError.failed("The selected text changed. Select it again before accepting.")
        }
        if settable.boolValue {
            guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else { throw ToolError.failed("This app couldn't replace the selection.") }
            if !(await Self.waitForValue(expected, element: element)) {
                // Some browser fields report success but ignore AXSelectedText. A full-value
                // retry is safe only while both the original value and selection still match.
                guard isCurrent else { throw ToolError.failed("The app didn't confirm the replacement. Check the original field before trying again.") }
                AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
                guard settable.boolValue, AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, expected as CFString) == .success else {
                    throw ToolError.failed("This app couldn't replace the selection. Copy the suggestion instead.")
                }
            }
        } else {
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            guard settable.boolValue else {
                throw ToolError.unavailable("This app doesn't allow accessible text replacement. The suggestion stays available to select and copy.")
            }
            guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, expected as CFString) == .success else { throw ToolError.failed("The app rejected the text change.") }
        }
        if !(await Self.waitForValue(expected, element: element)) {
            throw ToolError.failed("The app didn't confirm the replacement. Check the original field before trying again.")
        }
        return TextReplacement(element: element, before: previous, after: expected, original: original, replacement: text, range: range)
    }
    /// Cross-process accessibility writes can complete after the setter returns. Yield to
    /// the run loop while checking readback; never claim success from the setter alone.
    static func waitForValue(_ expected: String, element: AXUIElement) async -> Bool {
        for delay in [0, 30, 60, 120, 240, 300] {
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            if string(element, kAXValueAttribute) == expected { return true }
        }
        return false
    }
    static func validRange(_ range: CFRange, value: String) -> Bool {
        range.location >= 0 && range.length > 0 && range.location <= value.utf16.count && range.length <= value.utf16.count - range.location
    }
    static func isEditable(_ element: AXUIElement) -> Bool {
        func flag(_ attribute: String) -> Bool? {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let flag = value as? Bool { return flag }
            return nil
        }
        var selected = DarwinBoolean(false), value = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selected)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &value)
        return EditableTextPolicy.permits(role: string(element, kAXRoleAttribute),
            secure: string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole,
            editable: flag("AXEditable"), enabled: flag(kAXEnabledAttribute),
            selectedTextSettable: selected.boolValue, valueSettable: value.boolValue)
    }
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let wrapped = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(wrapped) == .cfRange else { return nil }
        var range = CFRange(); guard AXValueGetValue(wrapped, .cfRange, &range) else { return nil }; return range
    }
}
@MainActor
private final class TextReplacement: WritingReplacement {
    let element: AXUIElement
    let before: String?
    let after: String?
    let original: String
    let replacement: String
    let range: CFRange
    init(element: AXUIElement, before: String?, after: String?, original: String, replacement: String, range: CFRange) {
        self.element = element; self.before = before; self.after = after; self.original = original; self.replacement = replacement; self.range = range
    }
    func undo() async throws -> String {
        guard let before, let after, TextSelectionSnapshot.string(element, kAXValueAttribute) == after else {
            throw ToolError.failed("The field changed after the rewrite; undo was stopped.")
        }
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard settable.boolValue, AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, before as CFString) == .success,
              await TextSelectionSnapshot.waitForValue(before, element: element) else { throw ToolError.failed("This app couldn't restore the previous text.") }
        return "Restored the text before IVY's rewrite."
    }
}
