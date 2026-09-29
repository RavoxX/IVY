import Foundation
import Testing
@testable import IVYCore

private let router = CommandRouter(resolveApp: { name in ["safari": "Safari"][name.lowercased()] })

@Suite("File search")
struct FileSearchTests {
    @Test func parsesNaturalRequests() {
        #expect(FileSearchRequest.parse("find files named invoice") == FileSearchRequest(name: "invoice"))
        #expect(FileSearchRequest.parse("where is my tax return pdf") == FileSearchRequest(name: "tax return", kind: .pdf))
        #expect(FileSearchRequest.parse("find pdfs from last week") == FileSearchRequest(kind: .pdf, modified: .lastWeek))
        #expect(FileSearchRequest.parse("find the budget spreadsheet from yesterday")
            == FileSearchRequest(name: "budget", kind: .spreadsheet, modified: .yesterday))
        #expect(FileSearchRequest.parse("search my downloads for zip files") == FileSearchRequest(kind: .archive, folder: "downloads"))
        #expect(FileSearchRequest.parse("find pdf files in my documents folder") == FileSearchRequest(kind: .pdf, folder: "documents"))
        #expect(FileSearchRequest.parse("find files i downloaded today") == FileSearchRequest(modified: .today))
    }

    @Test func leavesOtherQuestionsAlone() {
        #expect(FileSearchRequest.parse("find me a restaurant") == nil)
        #expect(FileSearchRequest.parse("where is the eiffel tower") == nil)
        #expect(FileSearchRequest.parse("search for cats") == nil)
        #expect(FileSearchRequest.parse("find files") == nil)
    }

    @Test func buildsSpotlightPredicate() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let format = FileSearchRequest(name: "tax return", kind: .pdf, modified: .last7Days).predicate(now: now).predicateFormat
        #expect(format.contains("kMDItemFSName LIKE[cd] \"*tax*\""))
        #expect(format.contains("kMDItemFSName LIKE[cd] \"*return*\""))
        #expect(format.contains("kMDItemContentTypeTree == \"com.adobe.pdf\""))
        #expect(format.contains("kMDItemFSContentChangeDate >= CAST("))
    }

    @Test func summaries() {
        #expect(FileSearchRequest(name: "invoice", kind: .pdf).summary(count: 3) == "Found 3 PDFs named “invoice”.")
        #expect(FileSearchRequest(kind: .image, modified: .today).summary(count: 0) == "No images from today.")
    }

    @Test func routes() {
        #expect(router.route("Find PDFs from last week")
            == ToolCall(name: ToolName.fileSearch, arguments: ["kind": "pdf", "modified": "last_week"]))
    }
}

@Suite("Clipboard")
struct ClipboardTests {
    @Test func convertsCSVToJSONAndBack() throws {
        let json = try #require(ClipboardTransforms.csvToJSON("name,age,active\nAda,36,true\n\"Lovelace, A.\",28,false"))
        let objects = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(objects.count == 2)
        #expect(objects[0]["age"] as? Int == 36)
        #expect(objects[1]["name"] as? String == "Lovelace, A.")
        let csv = try #require(ClipboardTransforms.jsonToCSV(#"[{"name":"Ada","age":36},{"name":"Bo, Jr","age":2}]"#))
        #expect(csv == "age,name\n36,Ada\n2,\"Bo, Jr\"")
        #expect(ClipboardTransforms.csvToJSON("just a sentence, really") == nil)
    }

    @Test func tabSeparatedSpreadsheetPaste() {
        let rows = ClipboardTransforms.parseCSV("a\tb\n1\t2\n")
        #expect(rows == [["a", "b"], ["1", "2"]])
    }

    @Test func extractsWithoutTheModel() {
        let text = "Mail ada@example.com or bob@test.org, see https://apple.com and ada@example.com."
        #expect(ClipboardTransforms.extractEmails(from: text) == ["ada@example.com", "bob@test.org"])
        #expect(ClipboardTransforms.extractLinks(from: text) == ["https://apple.com"])
        #expect(ClipboardTransforms.deterministic(.summarize, text: text) == nil)
        #expect(ClipboardTransforms.deterministic(.wordCount, text: "one two\nthree") == "3 words · 13 characters · 2 lines")
    }

    @Test func cleansModelOutputAndGuardsPrompt() {
        #expect(ClipboardTransforms.cleanModelOutput("```json\n{\"a\": 1}\n```") == "{\"a\": 1}")
        #expect(ClipboardTransforms.cleanModelOutput("Here is the summary:\nShort.") == "Short.")
        let prompt = ClipboardTransforms.userPrompt(action: .translate, detail: "German", text: "Hello")
        #expect(prompt.contains("German") && prompt.contains("<<<\nHello\n>>>"))
    }

    @Test func parsesIntents() {
        #expect(ClipboardTransforms.parseIntent("summarize my clipboard")?.action == .summarize)
        #expect(ClipboardTransforms.parseIntent("summarize this")?.action == .summarize)
        #expect(ClipboardTransforms.parseIntent("turn the clipboard into json")?.action == .toJSON)
        #expect(ClipboardTransforms.parseIntent("extract the emails from my clipboard")?.action == .extractEmails)
        #expect(ClipboardTransforms.parseIntent("what's on my clipboard")?.action == .show)
        let translate = ClipboardTransforms.parseIntent("translate what i copied to german")
        #expect(translate?.action == .translate && translate?.detail == "German")
        #expect(ClipboardTransforms.parseIntent("summarize the news") == nil)
        #expect(router.route("Make a table from my clipboard")
            == ToolCall(name: ToolName.clipboard, arguments: ["action": "to_table"]))
    }
}

@Suite("Dictionary")
struct DictionaryTests {
    @Test func parsesLookups() {
        #expect(WordLookup.parse("define serendipity")?.word == "serendipity")
        #expect(WordLookup.parse("what does ubiquitous mean")?.mode == .define)
        #expect(WordLookup.parse("synonyms for happy").map { [$0.word, $0.mode.rawValue] } == ["happy", "synonyms"])
        #expect(WordLookup.parse("another word for big")?.word == "big")
        #expect(WordLookup.parse("what's the opposite of cold").map { [$0.word, $0.mode.rawValue] } == ["cold", "antonyms"])
        #expect(WordLookup.parse("what does this error in my code mean") == nil)
        #expect(router.route("Synonyms for happy?")
            == ToolCall(name: ToolName.dictionary, arguments: ["word": "happy", "mode": "synonyms"]))
    }

    @Test func parsesModelLists() {
        #expect(WordLookup.parseList("1. glad, 2. Cheerful\n- joyful (informal), happy, glad", excluding: "happy")
            == ["glad", "Cheerful", "joyful"])
        #expect(WordLookup.parseList("Synonyms: big, large, huge", excluding: "big") == ["large", "huge"])
    }

    @Test func trimsSystemDictionaryText() {
        let raw = "hap·py | ˈhapē | adjective (happier, happiest) 1 feeling or showing pleasure or contentment. 2 fortunate. ORIGIN Middle English"
        #expect(WordLookup.cleanDefinition(raw) == "hap·py | ˈhapē | adjective (happier, happiest) 1 feeling or showing pleasure or contentment.")
        let german = "Serendipität | noun glücklicher Zufall HERKUNFT englisch serendipity"
        #expect(WordLookup.cleanDefinition(german) == "Serendipität | noun glücklicher Zufall")
    }
}

@Suite("Mail")
struct MailTests {
    let inbox = [
        MailMessageItem(id: "1", sender: "Alex Kim <alex@example.com>", subject: "Invoice March", date: Date(timeIntervalSince1970: 300), isRead: false),
        MailMessageItem(id: "2", sender: "news@shop.com", subject: "Sale!", date: Date(timeIntervalSince1970: 200), isRead: false),
        MailMessageItem(id: "3", sender: "Álex Kim <alex@example.com>", subject: "Lunch?", date: Date(timeIntervalSince1970: 100), isRead: true),
    ]

    @Test func filters() {
        #expect(MailFilter.filter(inbox, from: "alex").map(\.id) == ["1", "3"])
        #expect(MailFilter.filter(inbox, from: "alex", unreadOnly: true).map(\.id) == ["1"])
        #expect(MailFilter.filter(inbox, query: "invoice").map(\.id) == ["1"])
        #expect(MailFilter.filter(inbox, since: Date(timeIntervalSince1970: 150)).map(\.id) == ["1", "2"])
        #expect(MailFilter.senderName("Alex Kim <alex@example.com>") == "Alex Kim")
        #expect(MailFilter.senderName("<solo@example.com>") == "solo@example.com")
    }

    @Test func summaries() {
        let fromAlex = MailFilter.filter(inbox, from: "alex", unreadOnly: true)
        #expect(MailFilter.summary(for: fromAlex, from: "alex", query: nil, unreadOnly: true)
            == "You have one unread email from Alex. Latest: “Invoice March”.")
        #expect(MailFilter.summary(for: [], from: nil, query: nil, unreadOnly: true) == "No unread email in your inbox.")
    }

    @Test func parsesRequests() {
        #expect(MailFilter.parse("any new mail from alex") == MailFilter.Request(from: "alex", query: nil, unreadOnly: true))
        #expect(MailFilter.parse("do i have emails from my landlord")?.from == "my landlord")
        #expect(MailFilter.parse("search for invoice in my inbox") == MailFilter.Request(from: nil, query: "invoice", unreadOnly: false))
        #expect(MailFilter.parse("check my email")?.unreadOnly == true)
        #expect(MailFilter.parse("send an email to alex") == nil)
        #expect(router.route("Any new mail from Alex?")
            == ToolCall(name: ToolName.mailSearch, arguments: ["from": "alex", "unread_only": true]))
    }
}

@Suite("Shortcuts, Focus and chains")
struct ShortcutFocusTests {
    let shortcuts = [
        ShortcutInfo(name: "Alle Lampen ein/aus", id: "A"),
        ShortcutInfo(name: "Lights", id: "B"),
        ShortcutInfo(name: "Set Thermostat", id: "C"),
        ShortcutInfo(name: "Work Focus", id: "D"),
        ShortcutInfo(name: "Focus Off", id: "E"),
        ShortcutInfo(name: "Unlock Front Door", id: "F"),
    ]

    @Test func matchesShortcuts() {
        #expect(ShortcutMatcher.best(for: "lights", in: shortcuts)?.id == "B")
        #expect(ShortcutMatcher.best(for: "thermostat", in: shortcuts)?.id == "C")
        #expect(ShortcutMatcher.best(for: "alle lampen", in: shortcuts)?.id == "A")
        #expect(ShortcutMatcher.best(for: "order pizza", in: shortcuts) == nil)
        #expect(ShortcutMatcher.isSensitive("Unlock Front Door"))
        #expect(!ShortcutMatcher.isSensitive("Lights"))
        #expect(ShortcutMatcher.focusShortcut(named: "Work", on: true, in: shortcuts)?.id == "D")
        #expect(ShortcutMatcher.focusShortcut(named: nil, on: false, in: shortcuts)?.id == "E")
        #expect(ShortcutMatcher.focusShortcut(named: "Sleep", on: true, in: shortcuts) == nil)
    }

    @Test func readsFocusDatabase() {
        let assertions = Data(#"{"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.work"}}]}]}"#.utf8)
        let configurations = Data(#"{"data":[{"modeConfigurations":{"com.apple.focus.work":{"mode":{"name":"Arbeit"}}}}]}"#.utf8)
        let identifier = FocusParser.activeModeIdentifier(assertions: assertions)
        #expect(identifier == "com.apple.focus.work")
        #expect(FocusParser.displayName(for: "com.apple.focus.work", names: FocusParser.modeNames(configurations: configurations)) == "Arbeit")
        #expect(FocusParser.activeModeIdentifier(assertions: Data(#"{"data":[{"storeAssertionRecords":[]}]}"#.utf8)) == nil)
        #expect(FocusParser.displayName(for: "com.apple.sleep.sleep-mode", names: [:]) == "Sleep")
        #expect(FocusParser.isQuiet("Do Not Disturb") && !FocusParser.isQuiet("Work"))
        #expect(FocusParser.replyGuidance(for: "Work").contains("professional"))
    }

    @Test func focusNamesFromEverydayWords() {
        let known = ["Do Not Disturb", "Sleep", "Work", "Personal", "Reading"]
        #expect(FocusParser.canonicalName("sleeping", known: known) == "Sleep")
        #expect(FocusParser.canonicalName("Working", known: known) == "Work")
        #expect(FocusParser.canonicalName("dnd", known: known) == "Do Not Disturb")
        #expect(FocusParser.canonicalName("reading mode", known: known) == "Reading")
        #expect(FocusParser.canonicalName("schlafen", known: known) == "Sleep")
        #expect(FocusParser.canonicalName("gaming", known: known) == "Gaming")
        let withSleep = shortcuts + [ShortcutInfo(name: "Sleep Focus", id: "G")]
        #expect(ShortcutMatcher.focusShortcut(named: "Sleeping", on: true, in: withSleep)?.id == "G")
        #expect(router.route("Set my focus to sleeping.") == ToolCall(name: ToolName.focus, arguments: ["action": "on", "name": "Sleeping"]))
    }

    @Test func resolvesLocalizedFocusModes() throws {
        let german = ["com.apple.sleep.sleep-mode": "Schlafen", "com.apple.focus.work": "Arbeit",
                      "com.apple.donotdisturb.mode.default": "Nicht stören"]
        #expect(FocusParser.resolve("sleeping", configured: german)?.name == "Schlafen")
        #expect(FocusParser.resolve("Arbeit", configured: german)?.identifier == "com.apple.focus.work")
        #expect(FocusParser.resolve("dnd", configured: german)?.name == "Nicht stören")
        #expect(FocusParser.resolve("low power", configured: german) == nil)
        let standard = try #require(FocusParser.resolve("Sleeping", configured: [:]))
        #expect(standard.name == "Sleep" && standard.identifier == "com.apple.sleep.sleep-mode")
        // Without Full Disk Access: macOS's localized names, which Set Focus matches by name.
        let systemGerman = ["Do Not Disturb": "Nicht stören", "Sleep": "Schlafen", "Work": "Arbeiten", "Personal": "Zeit für mich"]
        #expect(FocusParser.resolve("Do Not Disturb", configured: [:], localized: systemGerman)?.name == "Nicht stören")
        #expect(FocusParser.resolve("nicht stören", configured: [:], localized: systemGerman)?.identifier == "com.apple.donotdisturb.mode.default")
        #expect(FocusParser.resolve("sleeping", configured: [:], localized: systemGerman)?.name == "Schlafen")
        #expect(FocusParser.resolve("Arbeiten", configured: [:], localized: systemGerman)?.identifier == "com.apple.focus.work")
        #expect(FocusParser.resolve("zeit für mich", configured: [:], localized: systemGerman)?.name == "Zeit für mich")
        // An old English-named shortcut isn't reused for the German mode; the exact name wins.
        let list = [ShortcutInfo(name: "Do Not Disturb Focus", id: "old"), ShortcutInfo(name: "Nicht stören Focus", id: "new")]
        #expect(ShortcutMatcher.focusShortcut(named: "Nicht stören", on: true, in: list)?.id == "new")
    }

    @Test func buildsImportableShortcuts() throws {
        let data = try ShortcutBuilder.focusWorkflow(focus: "Sleep", identifier: "com.apple.sleep.sleep-mode", on: true)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let action = try #require((plist["WFWorkflowActions"] as? [[String: Any]])?.first)
        #expect(action["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.dnd.set")
        let parameters = try #require(action["WFWorkflowActionParameters"] as? [String: Any])
        #expect(parameters["Enabled"] as? Int == 1)
        #expect((parameters["FocusModes"] as? [String: String])?["Identifier"] == "com.apple.sleep.sleep-mode")


        #expect(ShortcutBuilder.focusShortcutName(focus: "Sleep", on: true) == "Sleep Focus")
        #expect(ShortcutBuilder.focusShortcutName(focus: nil, on: false) == "Focus Off")
        #expect(ShortcutBuilder.safeFileName("Work/School: 🎒") == "Work School  🎒")
    }

    @Test func offShortcutsPreferTheNamedMode() {
        let list = [ShortcutInfo(name: "Focus Off", id: "1"), ShortcutInfo(name: "Sleep Focus Off", id: "2"),
                    ShortcutInfo(name: "Work Focus", id: "3")]
        #expect(ShortcutMatcher.focusShortcut(named: "Sleep", on: false, in: list)?.id == "2")
        #expect(ShortcutMatcher.focusShortcut(named: "Work", on: false, in: list)?.id == "1")
        #expect(ShortcutMatcher.focusShortcut(named: nil, on: false, in: list)?.id == "1")
    }

    @Test func lowPowerAndSetupRoutes() {
        #expect(router.route("Activate low power mode") == ToolCall(name: ToolName.lowPowerMode, arguments: ["action": "on"]))
        #expect(router.route("turn off low power mode") == ToolCall(name: ToolName.lowPowerMode, arguments: ["action": "off"]))
        #expect(router.route("Is low power mode on?") == ToolCall(name: ToolName.lowPowerMode, arguments: ["action": "status"]))
        #expect(router.route("Can you create a shortcut for when I ask you to set my focus to sleeping that it sets my focus to sleeping?")
            == ToolCall(name: ToolName.focus, arguments: ["action": "setup", "name": "Sleeping"]))
        #expect(router.route("turn off sleep focus") == ToolCall(name: ToolName.focus, arguments: ["action": "off", "name": "Sleep"]))
    }

    @Test func focusRoutes() {
        #expect(router.route("Turn on work focus") == ToolCall(name: ToolName.focus, arguments: ["action": "on", "name": "Work"]))
        #expect(router.route("What focus is on?") == ToolCall(name: ToolName.focus, arguments: ["action": "status"]))
        #expect(router.route("turn off focus") == ToolCall(name: ToolName.focus, arguments: ["action": "off"]))
        #expect(router.route("run the shortcut lights") == ToolCall(name: ToolName.shortcutRun, arguments: ["name": "lights"]))
    }

    @Test func detectsChainedRequests() {
        #expect(ChainDetector.isCompound("remind me tomorrow at 9 to call alex, and set it up in calendar too"))
        #expect(ChainDetector.isCompound("pause the music and then open safari"))
        #expect(!ChainDetector.isCompound("remind me to buy milk and eggs"))
        #expect(!ChainDetector.isCompound("play rock and roll"))
        #expect(!ChainDetector.isCompound("set a timer for 1 minute and 30 seconds"))
        // Chained sentences skip the fast path, except the deliberate browser/coding phrasings.
        #expect(router.route("Remind me tomorrow at 9 to call Alex, and set it up in Calendar too") == nil)
        #expect(router.route("remind me to buy milk and eggs")?.name == ToolName.remindersCreate)
        #expect(router.route("open safari and search for cats")?.name == ToolName.browserSearch)
    }
}

@Suite("Energy")
struct EnergyTests {
    @Test func policies() {
        #expect(EnergyAdvisor.policy(for: EnergySnapshot(percent: 80, isPluggedIn: true)) == .normal)
        #expect(EnergyAdvisor.policy(for: EnergySnapshot(percent: 80, thermal: .serious)) == .conserve(idleMinutes: 2))
        #expect(EnergyAdvisor.policy(for: EnergySnapshot(percent: 80, thermal: .critical)) == .unloadNow)
        #expect(EnergyAdvisor.policy(for: EnergySnapshot(percent: 20)) == .conserve(idleMinutes: 3))
        #expect(EnergyAdvisor.policy(for: EnergySnapshot(percent: 8)) == .unloadNow)
        #expect(EnergyAdvisor.policy(for: EnergySnapshot(percent: 8, isPluggedIn: true)) == .normal)
        #expect(EnergyAdvisor.policy(for: EnergySnapshot(percent: 90, lowPowerMode: true)) == .conserve(idleMinutes: 3))
    }

    @Test func advice() {
        let low = EnergySnapshot(percent: 15, cycleCount: 400, healthPercent: 78, minutesRemaining: 75)
        #expect(EnergyAdvisor.advice(for: low).first == "Charge soon (about 1 h 15 min left).")
        #expect(EnergyAdvisor.advice(for: low).contains { $0.contains("health is 78%") })
        #expect(EnergyAdvisor.summary(for: low) == "Battery at 15%, health 78%, 400 cycles. Charge soon (about 1 h 15 min left).")
        let full = EnergySnapshot(percent: 100, isPluggedIn: true)
        #expect(EnergyAdvisor.advice(for: full).first?.hasPrefix("Fully charged") == true)
    }

    @Test func routes() {
        #expect(router.route("How's my battery health?") == ToolCall(name: ToolName.energyStatus))
        #expect(router.route("Should I charge my Mac?") == ToolCall(name: ToolName.energyStatus))
        #expect(router.route("Is my Mac overheating?") == ToolCall(name: ToolName.energyStatus))
        #expect(router.route("How much battery do I have?")?.name == ToolName.systemInfo)
    }
}
