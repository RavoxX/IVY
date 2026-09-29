import CoreGraphics
import Foundation
import Testing
@testable import IVYCore

@Suite("Reminder transformations")
struct ReminderTransformTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 12))! }

    func at(day: Int, hour: Int? = nil) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour ?? 0))!
    }

    var items: [ReminderItem] {
        [
            ReminderItem(id: "1", title: "Get homework done", dueDate: at(day: 29), hasDueTime: false),
            ReminderItem(id: "2", title: "Meeting at 7pm", dueDate: at(day: 29, hour: 19), hasDueTime: true),
            ReminderItem(id: "3", title: "Negotiate deals for VoiceOS", dueDate: at(day: 29, hour: 9), hasDueTime: true),
            ReminderItem(id: "4", title: "Pay rent", dueDate: at(day: 27), hasDueTime: false),
            ReminderItem(id: "5", title: "Dentist", dueDate: at(day: 2 + 30, hour: 10), hasDueTime: true),
            ReminderItem(id: "6", title: "Done thing", dueDate: at(day: 29), hasDueTime: false, isCompleted: true),
            ReminderItem(id: "7", title: "Someday", dueDate: nil, hasDueTime: false),
        ]
    }

    @Test func today() {
        let today = ReminderTransforms.filter(items, scope: .today, now: now, calendar: calendar)
        #expect(today.map(\.id) == ["1", "3", "2"])
        #expect(ReminderTransforms.summary(for: today, scope: .today) == "You have three reminders due today.")
    }

    @Test func overdue() {
        let overdue = ReminderTransforms.filter(items, scope: .overdue, now: now, calendar: calendar)
        // Timed reminder at 9:00 today is overdue at noon; all-day today is not.
        #expect(Set(overdue.map(\.id)) == ["4", "3"])
    }

    @Test func upcomingAndAll() {
        #expect(ReminderTransforms.filter(items, scope: .upcoming, now: now, calendar: calendar).map(\.id) == ["5"])
        let all = ReminderTransforms.filter(items, scope: .all, now: now, calendar: calendar)
        #expect(all.count == 6)
        #expect(all.last?.id == "7") // undated last
    }

    @Test func summaries() {
        #expect(ReminderTransforms.summary(for: [], scope: .today) == "Nothing due today.")
        let one = [ReminderItem(id: "a", title: "x", dueDate: now, hasDueTime: false)]
        #expect(ReminderTransforms.summary(for: one, scope: .today, overdueCount: 2)
            == "You have one reminder due today. Two are overdue.")
    }

    @Test func matching() {
        #expect(ReminderTransforms.bestMatch(for: "homework", in: items)?.id == "1")
        #expect(ReminderTransforms.bestMatch(for: "the voiceos deals", in: items)?.id == "3")
        #expect(ReminderTransforms.bestMatch(for: "zzz", in: items) == nil)
    }
}

@Suite("Settings persistence")
struct SettingsStoreTests {
    func makeStore() -> SettingsStore {
        let suite = "ivy.tests.\(UUID().uuidString)"
        return SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test func defaults() {
        let store = makeStore()
        #expect(store.ttsEnabled == false) // Voice responses are OFF by default.
        #expect(store.activationShortcut == .commandOption)
        #expect(store.gestureConfiguration.holdDuration == 0.5)
        #expect(store.string(.llmModelID) == "qwen3-4b-4bit")
        #expect(store.bool(.fastCommandRouting))
    }

    @Test func persistsAndResets() {
        let store = makeStore()
        store.ttsEnabled = true
        store.activationShortcut = .controlOption
        store.set(true, for: .hasCompletedSetup)
        let reloaded = SettingsStore(defaults: store.defaults)
        #expect(reloaded.ttsEnabled)
        #expect(reloaded.activationShortcut == .controlOption)
        reloaded.reset()
        #expect(reloaded.ttsEnabled == false)
        #expect(reloaded.activationShortcut == .commandOption)
        #expect(reloaded.bool(.hasCompletedSetup)) // setup state survives a reset
    }
}

@Suite("History")
struct HistoryStoreTests {
    @Test func appendsLimitsPersistsAndClears() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ivy-history-\(UUID().uuidString).json")
        let store = HistoryStore(fileURL: url, limit: 3)
        for index in 0..<5 {
            await store.append(HistoryEntry(query: "q\(index)", title: "t", toolName: nil, result: "r", status: .success))
        }
        let entries = await store.all()
        #expect(entries.map(\.query) == ["q4", "q3", "q2"])

        let reloaded = HistoryStore(fileURL: url, limit: 3)
        #expect(await reloaded.all().count == 3)

        let id = entries[0].id
        await reloaded.update(id: id) { $0.status = .failure }
        #expect(await reloaded.all().first?.status == .failure)

        await reloaded.clear()
        #expect(await reloaded.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func titles() {
        #expect(HistoryStore.title(forTool: ToolName.remindersList, query: "") == "Daily Reminder Overview")
        #expect(HistoryStore.title(forTool: ToolName.musicPlay, query: "") == "Spotify Music Playback")
        #expect(HistoryStore.title(forTool: nil, query: "what is the capital of australia") == "what is the capital of")
    }
}

@Suite("Security classification")
struct SecurityTests {
    struct StubTool: IVYTool {
        var name = "stub"
        var description = ""
        var parameters: [ToolParameter] = []
        var displayName = "Stub"
        var baseRisk: RiskLevel
        func execute(arguments: [String: JSONValue], context: ToolContext) async throws -> ToolResult { .init(summary: "") }
    }

    @Test func defaultPolicyConfirmsOnlyHighRisk() {
        let policy = SecurityPolicy()
        #expect(!policy.requiresConfirmation(.low))
        #expect(!policy.requiresConfirmation(.medium))
        #expect(policy.requiresConfirmation(.high))
        #expect(policy.requiresConfirmation(tool: StubTool(baseRisk: .high), arguments: [:]))
    }

    @Test func stricterPolicyCanConfirmMedium() {
        let policy = SecurityPolicy(confirmationThreshold: .medium)
        #expect(policy.requiresConfirmation(.medium))
        #expect(!policy.requiresConfirmation(.low))
    }

    @Test func allowlistRiskClasses() {
        #expect(CommandAllowlist.command(id: "git_status")?.risk == .low)
        #expect(CommandAllowlist.command(id: "npm_install")?.risk == .high)
        #expect(CommandAllowlist.command(id: "rm_rf") == nil)
    }

    @Test func destructivePathValidation() {
        let home = "/Users/tester"
        if case .success = CommandAllowlist.validateDestructivePath("/System/Library/x", home: home) { Issue.record("system path allowed") }
        if case .success = CommandAllowlist.validateDestructivePath("~/Documents", home: home) { Issue.record("top-level allowed") }
        if case .success = CommandAllowlist.validateDestructivePath("/Users/tester/Library/Preferences/x.plist", home: home) {
            Issue.record("library allowed")
        }
        if case .success = CommandAllowlist.validateDestructivePath("/Users/tester/../other/file", home: home) {
            Issue.record("traversal allowed")
        }
        if case .failure = CommandAllowlist.validateDestructivePath("/Users/tester/Downloads/old.zip", home: home) {
            Issue.record("valid file rejected")
        }
    }
}

@Suite("Notch geometry")
struct NotchGeometryTests {
    @Test func notchedBuiltInDisplay() {
        // 13" MacBook Air: 1470×956 points, 32 pt notch band.
        let frame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let geometry = NotchGeometry.make(screenFrame: frame, visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 924),
                                          safeAreaTop: 32,
                                          auxiliaryTopLeft: CGRect(x: 0, y: 924, width: 640, height: 32),
                                          auxiliaryTopRight: CGRect(x: 830, y: 924, width: 640, height: 32))
        #expect(geometry.hasNotch)
        #expect(geometry.notchWidth == 190)
        #expect(geometry.centerX == 735)
        #expect(geometry.topBandHeight == 32)
        let panel = geometry.panelFrame(size: CGSize(width: 400, height: 200))
        #expect(panel == CGRect(x: 535, y: 756, width: 400, height: 200))
    }

    @Test func halfPointNotchCenterSnapsToPixels() {
        // An odd notch width puts the center on a half point: keep it (Retina pixel), don't round it away.
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let geometry = NotchGeometry.make(screenFrame: frame, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
                                          safeAreaTop: 38,
                                          auxiliaryTopLeft: CGRect(x: 0, y: 944, width: 663, height: 38),
                                          auxiliaryTopRight: CGRect(x: 848, y: 944, width: 664, height: 38), scale: 2)
        #expect(geometry.centerX == 755.5)
        #expect(geometry.panelFrame(size: CGSize(width: 400, height: 38)).midX == 755.5)
        let nonRetina = NotchGeometry(screenFrame: frame, hasNotch: true, notchWidth: 185, topBandHeight: 38,
                                      centerX: 755.5, scale: 1)
        #expect(nonRetina.panelFrame(size: CGSize(width: 400, height: 38)).minX == 556)
    }

        @Test func externalDisplayWithoutNotch() {
        let frame = CGRect(x: 1470, y: 0, width: 2560, height: 1440)
        let geometry = NotchGeometry.make(screenFrame: frame, visibleFrame: CGRect(x: 1470, y: 0, width: 2560, height: 1415),
                                          safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        #expect(!geometry.hasNotch)
        #expect(geometry.centerX == 2750)
        #expect(geometry.topBandHeight == 25)
        #expect(geometry.panelFrame(size: CGSize(width: 400, height: 100)).maxY == 1440)
    }
}

@Suite("Date parsing")
struct DateParsingTests {
    @Test func isoFormats() throws {
        let calendar = Calendar.current
        let parsed = try #require(NaturalDateParser.parse("2026-10-02T18:00:00"))
        #expect(parsed.hasTime)
        #expect(calendar.component(.hour, from: parsed.date) == 18)
        let dateOnly = try #require(NaturalDateParser.parse("2026-10-02"))
        #expect(!dateOnly.hasTime)
    }

    @Test func naturalLanguage() throws {
        let calendar = Calendar.current
        let tomorrow = try #require(NaturalDateParser.parse("tomorrow"))
        #expect(!tomorrow.hasTime)
        #expect(calendar.isDateInTomorrow(tomorrow.date))

        let afternoon = try #require(NaturalDateParser.parse("tomorrow at 5"))
        #expect(afternoon.hasTime)
        #expect(calendar.component(.hour, from: afternoon.date) == 17)

        let morning = try #require(NaturalDateParser.parse("tomorrow at 5am"))
        #expect(calendar.component(.hour, from: morning.date) == 5)
    }
}
