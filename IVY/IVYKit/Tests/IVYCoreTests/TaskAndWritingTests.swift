import Foundation
import Testing
@testable import IVYCore

@Suite("Task models and editable writing")
struct TaskAndWritingTests {
    @Test("Writing button stays beside the selection and within display edges")
    func indicatorPlacement() throws {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let centered = try #require(WritingIndicatorPlacement.frame(selection: CGRect(x: 200, y: 300, width: 300, height: 40), visibleScreen: screen))
        #expect(centered.maxX < 200)
        #expect(centered.size == WritingIndicatorPlacement.size)
        let leftEdge = try #require(WritingIndicatorPlacement.frame(selection: CGRect(x: 0, y: 690, width: 100, height: 30), visibleScreen: screen))
        #expect(leftEdge.minX > 100)
        #expect(screen.contains(leftEdge))
        let negativeScreen = CGRect(x: -1440, y: -400, width: 1440, height: 900)
        let lowerEdge = try #require(WritingIndicatorPlacement.frame(selection: CGRect(x: -20, y: -410, width: 100, height: 20), visibleScreen: negativeScreen))
        #expect(negativeScreen.contains(lowerEdge))
        #expect(WritingIndicatorPlacement.frame(selection: .zero, visibleScreen: screen) == nil)
        #expect(WritingIndicatorPlacement.frame(selection: CGRect(x: 1, y: 1, width: 20, height: 20), visibleScreen: .zero) == nil)
    }
    @Test("Fast web research uses the selected research model without loading an unavailable command model")
    func independentResearchModel() async {
        let commandModel = UnavailableCommandModel()
        let researchModel = FakeLLM(responses: ["The tower is 330 meters tall."])
        let search = RecordingTool(name: ToolName.webSearch, terminal: false, summary: "Found source text.", requiresModelAnswer: true)
        let agent = AgentService(llm: commandModel, registry: ToolRegistry(tools: [search]), router: CommandRouter(resolveApp: { _ in nil }),
                                 writer: { researchModel }, confirm: { _ in true })
        var result: AgentOutcome?
        var routes: [AITask] = []
        for await event in agent.run("Search the internet for how tall the Eiffel Tower is") {
            if case .finished(let value) = event { result = value }
            if case .modelTask(let task) = event { routes.append(task) }
        }
        #expect(result?.status == .success)
        #expect(result?.text == "The tower is 330 meters tall.")
        #expect(researchModel.received.count == 1)
        #expect(search.calls.count == 1)
        #expect(routes.last == .research)
    }
    @Test("Static, read-only, disabled and secure selections never qualify for rewriting")
    func eligibleFields() {
        func allows(_ role: String, secure: Bool = false, editable: Bool? = nil, enabled: Bool? = nil, writable: Bool = true) -> Bool {
            EditableTextPolicy.permits(role: role, secure: secure, editable: editable, enabled: enabled,
                                       selectedTextSettable: writable, valueSettable: false)
        }
        #expect(allows("AXTextField"))
        #expect(allows("AXTextArea"))
        #expect(!allows("AXStaticText"))
        #expect(!allows("AXWebArea"))
        #expect(!allows("AXTextArea", editable: false))
        #expect(!allows("AXTextField", writable: false))
        #expect(!allows("AXTextField", enabled: false))
        #expect(!allows("AXTextField", secure: true))
    }
    @Test("Replacement preserves surrounding Unicode and rejects stale or invalid ranges")
    func replacements() {
        #expect(EditableTextPolicy.replacement(in: "👋 helo world", location: 3, length: 4, original: "helo", with: "hello") == "👋 hello world")
        for (location, length) in [(-1, 4), (3, Int.max), (Int.max, 4), (3, -1), (100, 4)] {
            #expect(EditableTextPolicy.replacement(in: "👋 helo world", location: location, length: length, original: "helo", with: "hello") == nil)
        }
        #expect(EditableTextPolicy.replacement(in: "👋 new world", location: 3, length: 4, original: "helo", with: "hello") == nil)
    }
    @Test("Word selections require a matching document body and valid positions")
    func wordSelectionValidation() throws {
        let selection = try #require(WordWritingSelection(documentName: "Document1", fullValue: "👋 helo\rnext\r", original: "helo", start: 3, end: 7))
        #expect(selection.replacement("hello")?.fullValue == "👋 hello\rnext\r")
        #expect(WordWritingSelection(documentName: "", fullValue: "text", original: "text", start: 0, end: 4) == nil)
        #expect(WordWritingSelection(documentName: "Document1", fullValue: "new text", original: "old", start: 0, end: 3) == nil)
        for (start, end) in [(-1, 4), (4, 3), (0, Int.max), (Int.max, Int.max), (0, 0)] {
            #expect(WordWritingSelection(documentName: "Document1", fullValue: "text", original: "text", start: start, end: end) == nil)
        }
        let tooLong = String(repeating: "a", count: 12_001)
        #expect(WordWritingSelection(documentName: "Document1", fullValue: tooLong, original: tooLong, start: 0, end: tooLong.count) == nil)
    }
    @Test("Word replacements normalize paragraphs and retain the document's final mark")
    func wordParagraphs() throws {
        let selection = try #require(WordWritingSelection(documentName: "Document1", fullValue: "before\rselected\r", original: "selected\r", start: 7, end: 16))
        #expect(selection.replacement("new\r\nparagraph\nlast")?.fullValue == "before\rnew\rparagraph\rlast\r")
        #expect(selection.replacement("new\r")?.text == "new\r")
        #expect(selection.replacement("") == nil)
        #expect(selection.replacement(String(repeating: "a", count: 40_001)) == nil)
        let middle = try #require(WordWritingSelection(documentName: "Document1", fullValue: "first\rsecond\r", original: "first\r", start: 0, end: 6))
        #expect(middle.replacement("changed\n")?.fullValue == "changed\rsecond\r")
        #expect(selection.replacement("\" & do shell script \"whoami\"")?.text == "\" & do shell script \"whoami\"\r")
    }
    @Test("Task choices persist, inherit commands, and explicitly route to different providers")
    func routing() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.setTaskModel(.init(provider: .gemini, model: "gemini-test"), for: .commands)
        #expect(store.modelChoice(for: .grammar) == .init(provider: .gemini, model: "gemini-test"))
        store.setTaskModel(.init(provider: .claude, model: "claude-test"), for: .grammar)
        store.setTaskModel(.init(provider: .local, model: "qwen-test"), for: .translation)
        #expect(store.modelChoice(for: .grammar).provider == .claude)
        #expect(store.modelChoice(for: .translation).provider == .local)
        #expect(store.routingMode == "Hybrid")
        store.setTaskModel(nil, for: .grammar)
        #expect(store.modelChoice(for: .grammar).provider == .gemini)
        store.set(AIProvider.openAI.rawValue, for: .writingProvider)
        #expect(store.modelChoice(for: .research).provider == .openAI)
    }
    @Test("Huge non-finite tool integers cannot trap conversion")
    func integerValidation() {
        #expect(["offset": JSONValue.number(1e100)].int("offset") == nil)
        #expect(["offset": JSONValue.number(.infinity)].int("offset") == nil)
        #expect(["offset": JSONValue.number(-60)].int("offset") == -60)
    }
    @Test("A compound request can complete more than two actions without replay")
    func threeActions() async {
        let llm = FakeLLM(responses: [
            #"<tool_call>{"name":"first","arguments":{}}</tool_call>"#,
            #"<tool_call>{"name":"second","arguments":{}}</tool_call>"#,
            #"<tool_call>{"name":"third","arguments":{}}</tool_call>"#,
            "Finished."
        ])
        let tools = ["first", "second", "third"].map { RecordingTool(name: $0, summary: $0 + " succeeded.") }
        let agent = AgentService(llm: llm, registry: ToolRegistry(tools: tools), router: CommandRouter(resolveApp: { _ in nil }),
                                 fastRoutingEnabled: { false }, confirm: { _ in true })
        var result: AgentOutcome?
        for await event in agent.run("Run first and run second and run third") { if case .finished(let value) = event { result = value } }
        #expect(tools.allSatisfy { $0.calls.count == 1 })
        #expect(result?.toolNames == ["first", "second", "third"])
        #expect(result?.text == "first succeeded. second succeeded. third succeeded.")
    }
    @Test("A repeated action is stopped before a second side effect")
    func duplicateAction() async {
        let call = #"<tool_call>{"name":"action","arguments":{}}</tool_call>"#
        let llm = FakeLLM(responses: [call, call])
        let tool = RecordingTool(name: "action", terminal: false)
        let agent = AgentService(llm: llm, registry: ToolRegistry(tools: [tool]), router: CommandRouter(resolveApp: { _ in nil }),
                                 fastRoutingEnabled: { false }, confirm: { _ in true })
        var result: AgentOutcome?
        for await event in agent.run("Do the action") { if case .finished(let value) = event { result = value } }
        #expect(tool.calls.count == 1)
        #expect(result?.status == .failure)
    }
    @Test("Nested connector schema validates required fields, types, lengths and enums")
    func connectorArguments() throws {
        let schema: JSONValue = ["type": "object", "required": ["message"], "additionalProperties": false,
                                "properties": ["message": ["type": "object", "required": ["text"],
                                                           "properties": ["text": ["type": "string", "maxLength": 10]]],
                                               "kind": ["type": "string", "enum": ["draft", "send"]]]]
        try MCPArgumentValidator.validate(["message": ["text": "hello"], "kind": "draft"], schema: schema)
        for bad: [String: JSONValue] in [
            ["message": ["text": "this is too long"]], ["message": [:]], ["message": ["text": 3]],
            ["message": ["text": "ok"], "kind": "delete"], ["message": ["text": "ok"], "secret": "hidden"]
        ] {
            #expect(throws: (any Error).self) { try MCPArgumentValidator.validate(bad, schema: schema) }
        }
    }
}

private final class UnavailableCommandModel: LocalLLMService, @unchecked Sendable {
    var isAvailable: Bool { false }
    var availabilityError: any Error { LocalModelError.runtimeNotInstalled }
    var isLoaded: Bool { get async { false } }
    func loadModel() async throws { throw availabilityError }
    func unloadModel() async {}
    func cancelGeneration() async {}
    func generate(messages: [ChatMessage], tools: [JSONValue], options: GenerationOptions,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> String { throw availabilityError }
}
