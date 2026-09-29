import AppKit
import IVYCore

/// Composition root: creates services once and wires tools, agent and UI together.
/// Heavy work (models, engine processes) is lazy, so launching IVY is instant.
@MainActor
final class AppEnvironment {
    let settings = SettingsStore()
    let permissions = PermissionService()
    let history = HistoryStore(fileURL: AppPaths.historyFile)
    let runtime: RuntimeManager
    let llm: MLXLLMService
    let whisper: LocalWhisperService
    let tts: KokoroMLXTTSService
    let spotify = SpotifyService()
    let music: MusicController
    let reminders = ReminderService()
    let claudeCode: ClaudeCodeService
    let appLauncher = AppLauncher()
    let shelf = ShelfStore()
    let battery = BatteryMonitor()
    let timers = TimerService()
    let calendar = CalendarService()
    let registry = ToolRegistry()
    private(set) var agent: AgentService!
    private(set) var notch: NotchViewModel!

    weak var shortcuts: GlobalShortcutManager?
    var settingsPresenter: ((String?) -> Void)?

    init() {
        runtime = RuntimeManager(settings: settings)
        llm = MLXLLMService(settings: settings)
        whisper = LocalWhisperService(settings: settings)
        tts = KokoroMLXTTSService(settings: settings)
        music = MusicController(spotify: spotify)
        claudeCode = ClaudeCodeService(settings: settings)

        registerTools()

        let launcher = appLauncher
        let router = CommandRouter(resolveApp: { launcher.resolve($0)?.name })
        let settings = self.settings
        agent = AgentService(
            llm: llm, registry: registry, router: router, policy: SecurityPolicy(),
            options: { settings.generationOptions },
            fastRoutingEnabled: { settings.bool(.fastCommandRouting) },
            confirm: { [weak self] request in
                guard let self else { return false }
                return await self.notch.requestConfirmation(request)
            })
        notch = NotchViewModel(env: self)
    }

    private func registerTools() {
        let musicContext = MusicToolContext(spotify: spotify, controller: music, settings: settings)
        let tools: [any IVYTool] = [
            RemindersListTool(service: reminders),
            RemindersCreateTool(service: reminders),
            RemindersCompleteTool(service: reminders),
            RemindersSearchTool(service: reminders),
            MusicPlayTool(context: musicContext),
            MusicControlTool(context: musicContext),
            MusicNowPlayingTool(context: musicContext),
            MusicVolumeTool(context: musicContext),
            OpenApplicationTool(launcher: appLauncher),
            OpenURLTool(launcher: appLauncher),
            BrowserSearchTool(launcher: appLauncher),
            WebSearchTool(settings: settings),
            TimerSetTool(timers: timers),
            TimerListTool(timers: timers),
            TimerCancelTool(timers: timers),
            WeatherTool(settings: settings),
            CalendarTool(service: calendar),
            SystemVolumeTool(),
            DarkModeTool(),
            SystemInfoTool(),
            CalculatorTool(),
            OpenFileTool(),
            RevealInFinderTool(),
            SettingsTool(open: { [weak self] section in
                await MainActor.run { [weak self] in self?.openSettings(section: section) }
            }),
            ClaudeCodeTool(service: claudeCode, settings: settings),
            MoveToTrashTool(),
            RunCommandTool(),
        ]
        tools.forEach(registry.register)
    }

    func openSettings(section: String? = nil) {
        settingsPresenter?(section)
    }
}
