import Foundation
import Testing
@testable import IVYCore

@Suite("CommandRouter")
struct CommandRouterTests {
    let installedApps = ["safari": "Safari", "spotify": "Spotify", "system settings": "System Settings",
                         "home": "Home", "notes": "Notes", "visual studio code": "Visual Studio Code"]

    var router: CommandRouter {
        let apps = installedApps
        return CommandRouter(resolveApp: { apps[$0.lowercased()] })
    }

    @Test func openIVYSettings() {
        for phrase in ["Open IVY settings.", "open ivy settings", "IVY settings", "Hey IVY, open your settings please",
                       "show IVY's preferences"] {
            #expect(router.route(phrase)?.name == ToolName.openSettings, "\(phrase)")
        }
    }

    @Test func musicControls() {
        #expect(router.route("Pause the music.") == ToolCall(name: ToolName.musicControl, arguments: ["action": "pause"]))
        #expect(router.route("pause") == ToolCall(name: ToolName.musicControl, arguments: ["action": "pause"]))
        #expect(router.route("Resume") == ToolCall(name: ToolName.musicControl, arguments: ["action": "resume"]))
        #expect(router.route("Next song") == ToolCall(name: ToolName.musicControl, arguments: ["action": "next"]))
        #expect(router.route("skip this song") == ToolCall(name: ToolName.musicControl, arguments: ["action": "next"]))
        #expect(router.route("Previous song") == ToolCall(name: ToolName.musicControl, arguments: ["action": "previous"]))
        #expect(router.route("What's playing?") == ToolCall(name: ToolName.musicNowPlaying))
        #expect(router.route("Play music.") == ToolCall(name: ToolName.musicPlay))
    }

    @Test func playSpecificSong() {
        #expect(router.route("Play Billie Jean.") == ToolCall(name: ToolName.musicPlay, arguments: ["query": "billie jean"]))
        #expect(router.route("play thriller by michael jackson on spotify")
            == ToolCall(name: ToolName.musicPlay, arguments: ["query": "thriller by michael jackson"]))
        #expect(router.route("play a game") == nil)
    }

    @Test func volume() {
        #expect(router.route("Turn the volume up") == ToolCall(name: ToolName.musicVolume, arguments: ["direction": "up"]))
        #expect(router.route("turn the volume down") == ToolCall(name: ToolName.musicVolume, arguments: ["direction": "down"]))
        #expect(router.route("set the volume to 40") == ToolCall(name: ToolName.musicVolume, arguments: ["level": 40]))
    }

    @Test func remindersToday() {
        for phrase in ["What's on my to-do list today?", "What's on my to-do list for today?", "what is on my todo list",
                       "Show my reminders", "What do I have to do today?"] {
            #expect(router.route(phrase) == ToolCall(name: ToolName.remindersList, arguments: ["scope": "today"]), "\(phrase)")
        }
        #expect(router.route("what's overdue") == ToolCall(name: ToolName.remindersList, arguments: ["scope": "overdue"]))
    }

    @Test func reminderCreation() throws {
        let call = try #require(router.route("Remind me tomorrow at 5 to call Alex."))
        #expect(call.name == ToolName.remindersCreate)
        #expect(call.arguments["title"] == "Call Alex")
        let due = try #require(call.arguments.string("due").flatMap { NaturalDateParser.parseISO($0) })
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        #expect(calendar.isDate(due.date, inSameDayAs: tomorrow))
        #expect(calendar.component(.hour, from: due.date) == 17)

        let undated = try #require(router.route("remind me to water the plants"))
        #expect(undated.arguments["title"] == "Water the plants")
        #expect(undated.arguments["due"] == nil)
    }

    @Test func openApplicationsURLsAndFolders() {
        #expect(router.route("Open Safari.") == ToolCall(name: ToolName.openApp, arguments: ["name": "Safari"]))
        #expect(router.route("launch spotify") == ToolCall(name: ToolName.openApp, arguments: ["name": "Spotify"]))
        #expect(router.route("Open github.com") == ToolCall(name: ToolName.openURL, arguments: ["url": "https://github.com"]))
        #expect(router.route("Open Downloads.") == ToolCall(name: ToolName.openFile, arguments: ["path": "~/Downloads"]))
        #expect(router.route("open my documents folder") == ToolCall(name: ToolName.openFile, arguments: ["path": "~/Documents"]))
        // "Home" is an app; only "home folder" means the folder.
        #expect(router.route("open home") == ToolCall(name: ToolName.openApp, arguments: ["name": "Home"]))
        #expect(router.route("open my home folder") == ToolCall(name: ToolName.openFile, arguments: ["path": "~"]))
        // Unknown apps and compound requests go to the model.
        #expect(router.route("open the thing I used yesterday") == nil)
        #expect(router.route("open safari and search for cats")
            == ToolCall(name: ToolName.browserSearch, arguments: ["query": "cats", "browser": "Safari"]))
    }

    @Test func claudeCodeSession() throws {
        let call = try #require(router.route("Can you open a Claude Code session for me and start building a personal website?"))
        #expect(call.name == ToolName.startCodingSession)
        #expect(call.arguments["project_name"] == "personal-website")
        #expect(call.arguments["task"] == "Build a personal website")
        #expect(call.arguments["agent"] == "claude")

        let second = try #require(router.route("Open Claude Code and start building a personal website."))
        #expect(second.arguments["project_name"] == "personal-website")
    }

    @Test func generalQuestionsGoToModel() {
        #expect(router.route("What's the capital of Australia?") == nil)
        #expect(router.route("How long does it take to boil an egg?") == nil)
        #expect(router.route("") == nil)
    }

    @Test func normalization() {
        #expect(CommandRouter.normalize("  Hey IVY, could you pause the music please?  ") == "pause the music")
        #expect(CommandRouter.normalize("IVY") == "")
    }
}

@Suite("ProjectNameSanitizer")
struct ProjectNameTests {
    @Test func sanitizes() {
        #expect(ProjectNameSanitizer.sanitize("My Cool App!!") == "my-cool-app")
        #expect(ProjectNameSanitizer.sanitize("../../etc/passwd") == "etc-passwd")
        #expect(ProjectNameSanitizer.sanitize("   ") == "ivy-project")
        #expect(ProjectNameSanitizer.sanitize("Café Übersicht") == "cafe-ubersicht")
    }

    @Test func derivesFromTask() {
        #expect(ProjectNameSanitizer.projectName(fromTask: "building a personal website") == "personal-website")
        #expect(ProjectNameSanitizer.projectName(fromTask: "create a todo app with react") == "todo-app")
    }
}
