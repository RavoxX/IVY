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
    let languageModel: ConfiguredLLMService
    /// Optional second model for writing answers (web search, clipboard); see Settings ▸ AI.
    let writerLLM: MLXLLMService
    let phrases = PhraseMemory(fileURL: AppPaths.applicationSupport.appendingPathComponent("learned-phrases.json"))
    let nudges: NudgeService
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
    let mail = MailService()
    let shortcutsService = ShortcutsService()
    let focus = FocusService()
    let fileSearch = FileSearchService()
    let governor = EnergyGovernor()
    let energy = EnergyMonitor()
    let textService: LLMTextService
    let glance: GlanceService
    let registry = ToolRegistry()
    private(set) var agent: AgentService!
    private(set) var notch: NotchViewModel!

    weak var shortcuts: GlobalShortcutManager?
    var settingsPresenter: ((String?) -> Void)?

    init() {
        runtime = RuntimeManager(settings: settings)
        llm = MLXLLMService(settings: settings, governor: governor)
        writerLLM = MLXLLMService(settings: settings, governor: governor, modelKey: .writingModelID)
        languageModel = ConfiguredLLMService(local: llm, settings: settings) { provider in
            Keychain.read(account: provider.keychainAccount) ?? ""
        }
        whisper = LocalWhisperService(settings: settings, governor: governor)
        tts = KokoroMLXTTSService(settings: settings, governor: governor)
        let activeWriter = Self.activeWriter(settings: settings, writer: writerLLM)
        textService = LLMTextService(main: languageModel, writer: activeWriter, settings: settings)
        nudges = NudgeService(settings: settings, calendar: calendar, energy: energy, focus: focus)
        glance = GlanceService(settings: settings, reminders: reminders, calendar: calendar, mail: mail,
                               focus: focus, energy: energy)
        music = MusicController(spotify: spotify)
        claudeCode = ClaudeCodeService(settings: settings)

        registerTools()

        let launcher = appLauncher
        let router = CommandRouter(resolveApp: { launcher.resolve($0)?.name })
        let settings = self.settings
        let focus = self.focus
        agent = AgentService(
            llm: languageModel, registry: registry, router: router, policy: SecurityPolicy(),
            options: { settings.generationOptions },
            fastRoutingEnabled: { settings.bool(.fastCommandRouting) },
            situation: {
                guard settings.bool(.focusAwareReplies), let name = focus.activeName else { return nil }
                return FocusParser.replyGuidance(for: name)
            },
            writer: activeWriter,
            phrases: phrases,
            confirm: { [weak self] request in
                guard let self else { return false }
                return await self.notch.requestConfirmation(request)
            })
        notch = NotchViewModel(env: self)

        runtime.unloadBeforeDelete = { [llm, writerLLM, whisper, tts] kind in
            switch kind {
            case .llm:
                await llm.unloadModel()
                await writerLLM.unloadModel()
            case .whisper: await whisper.unload()
            case .kokoro: await tts.unload()
            }
        }

        energy.onPolicyChange = { [weak self] policy in self?.applyEnergyPolicy(policy) }
        applyEnergyPolicy(energy.policy)
        // Warm the Shortcuts list so the model knows the user's Home shortcuts by name.
        let shortcutsService = self.shortcutsService
        Task.detached(priority: .utility) { _ = await shortcutsService.list() }
        nudges.onNudge = { [weak self] nudge in self?.notch.showNudge(nudge) }
        nudges.start()
    }

    /// The writing model, when one is chosen, differs from the main model and is downloaded.
    static func activeWriter(settings: SettingsStore, writer: MLXLLMService) -> @Sendable () -> (any LocalLLMService)? {
        {
            let id = settings.string(.writingModelID)
            guard settings.aiProvider == .local, !id.isEmpty, id != settings.string(.llmModelID) || !settings.string(.llmModelPath).isEmpty,
                  writer.isAvailable else { return nil }
            return writer
        }
    }

    /// Hot, Low Power Mode or low battery: unload idle models sooner (or now, if critical).
    func applyEnergyPolicy(_ policy: EnergyAdvisor.ModelPolicy) {
        let enabled = settings.bool(.energyAwareModels)
        switch enabled ? policy : .normal {
        case .normal: governor.setCap(minutes: nil)
        case .conserve(let minutes): governor.setCap(minutes: minutes)
        case .unloadNow: governor.setCap(minutes: 1)
        }
        let busy = notch?.isBusy ?? false
        Task { [llm, writerLLM, whisper, tts] in
            if enabled, policy == .unloadNow, !busy {
                await llm.unloadModel()
                await writerLLM.unloadModel()
                await whisper.unload()
                await tts.unload()
            } else {
                await llm.applyIdleTimeout()
                await writerLLM.applyIdleTimeout()
                await whisper.applyIdleTimeout()
                await tts.applyIdleTimeout()
            }
        }
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
            FileSearchTool(service: fileSearch),
            ClipboardTool(text: textService),
            DictionaryTool(text: textService),
            MailSearchTool(service: mail),
            CalendarCreateTool(service: calendar),
            ShortcutRunTool(service: shortcutsService),
            FocusTool(focus: focus, shortcuts: shortcutsService),
            LowPowerModeTool(),
            EnergyTool(monitor: energy, llm: llm),
        ]
        tools.forEach(registry.register)
    }

    func openSettings(section: String? = nil) {
        settingsPresenter?(section)
    }
}
