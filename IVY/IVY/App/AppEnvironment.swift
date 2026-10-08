import AppKit
import IVYCore

/// Composition root: creates services once and wires tools, agent and UI together.
/// Heavy work (models, engine processes) is lazy, so launching IVY is instant.
@MainActor
final class AppEnvironment {
    let settings: SettingsStore
    let permissions = PermissionService()
    let usage = UsageStore(fileURL: AppPaths.applicationSupport.appendingPathComponent("usage.json"))
    let routines = RoutineStore(fileURL: AppPaths.applicationSupport.appendingPathComponent("routines.json"))
    let updater = AppUpdater()
    let undo = UndoStore()
    let connectors: ConnectorManager
    let history = HistoryStore(fileURL: AppPaths.historyFile)
    let runtime: RuntimeManager
    let llm: MLXLLMService
    let languageModel: ConfiguredLLMService
    let taskModels: TaskLocalModelPool
    let writingAssist: WritingAssistService
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
    let faceUnlock: FaceUnlockService
    let registry = ToolRegistry()
    private(set) var agent: AgentService!
    private(set) var notch: NotchViewModel!

    weak var shortcuts: GlobalShortcutManager?
    var workspaceDraft = ""
    var workspaceAttachments: [URL] = []
    var selectionApplication: NSRunningApplication?
    var settingsPresenter: ((String?) -> Void)?

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        connectors = ConnectorManager(registry: registry)
        runtime = RuntimeManager(settings: settings)
        llm = MLXLLMService(settings: settings, governor: governor, usage: { [usage] in await usage.append($0) })
        writerLLM = MLXLLMService(settings: settings, governor: governor, modelKey: .writingModelID, usage: { [usage] in await usage.append($0) })
        taskModels = TaskLocalModelPool(settings: settings, governor: governor, usage: usage)
        languageModel = ConfiguredLLMService(local: llm, settings: settings, localModel: { [taskModels] in taskModels.model($0) }, usage: { [usage] in await usage.append($0) }) { provider in
            Keychain.read(account: provider.keychainAccount) ?? ""
        }
        whisper = LocalWhisperService(settings: settings, governor: governor)
        tts = KokoroMLXTTSService(settings: settings, governor: governor)
        textService = LLMTextService(main: languageModel, settings: settings)
        writingAssist = WritingAssistService(textService: textService, settings: settings, undo: undo)
        nudges = NudgeService(settings: settings, calendar: calendar, energy: energy, focus: focus)
        glance = GlanceService(settings: settings, reminders: reminders, calendar: calendar, mail: mail,
                               focus: focus, energy: energy)
        music = MusicController(spotify: spotify)
        faceUnlock = FaceUnlockService(settings: settings)
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
                var guidance = String(settings.string(.assistantPreferences).prefix(2000))
                if settings.bool(.focusAwareReplies), let name = focus.activeName { guidance += " " + FocusParser.replyGuidance(for: name) }
                return guidance.isEmpty ? nil : guidance
            },
            writer: { [languageModel] in languageModel.forTask(.research) },
            writerOptions: {
                var options = settings.generationOptions
                if settings.modelChoice(for: .research).provider != .local {
                    options.contextLength = 128_000
                    options.maxTokens = max(2048, settings.int(.cloudMaxResponseTokens))
                }
                return options
            },
            phrases: phrases,
            confirm: { [weak self] request in
                guard let self else { return false }
                return await self.notch.requestConfirmation(request)
            })
        notch = NotchViewModel(env: self)
        writingAssist.onPresent = { [weak self] in self?.notch.presentWritingAssist() }
        writingAssist.canPresentAutomatically = { [weak self] in
            self?.notch.isBusy == false && self?.notch.workspaceVisible == false && self?.notch.writingAssistVisible == false
        }
        Task { await agent.setConversationLifetime(minutes: settings.int(.conversationMinutes)) }

        runtime.unloadBeforeDelete = { [llm, writerLLM, taskModels, whisper, tts] kind in
            switch kind {
            case .llm:
                await llm.unloadModel()
                await writerLLM.unloadModel()
                await taskModels.unload()
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

    /// Hot, Low Power Mode or low battery: unload idle models sooner (or now, if critical).
    func applyEnergyPolicy(_ policy: EnergyAdvisor.ModelPolicy) {
        let enabled = settings.bool(.energyAwareModels)
        switch enabled ? policy : .normal {
        case .normal: governor.setCap(minutes: nil)
        case .conserve(let minutes): governor.setCap(minutes: minutes)
        case .unloadNow: governor.setCap(minutes: 1)
        }
        let busy = notch?.isBusy ?? false
        Task { [llm, writerLLM, taskModels, whisper, tts] in
            if enabled, policy == .unloadNow, !busy {
                await llm.unloadModel()
                await writerLLM.unloadModel()
                await taskModels.unload()
                await whisper.unload()
                await tts.unload()
            } else {
                await llm.applyIdleTimeout()
                await writerLLM.applyIdleTimeout()
                await taskModels.applyIdleTimeout()
                await whisper.applyIdleTimeout()
                await tts.applyIdleTimeout()
            }
        }
    }

    private func registerTools() {
        let musicContext = MusicToolContext(spotify: spotify, controller: music, settings: settings)
        let tools: [any IVYTool] = [
            UndoLastActionTool(store: undo),
            RemindersListTool(service: reminders),
            RemindersCreateTool(service: reminders, undo: undo),
            RemindersCompleteTool(service: reminders, undo: undo),
            RemindersSearchTool(service: reminders),
            MusicPlayTool(context: musicContext),
            MusicControlTool(context: musicContext),
            MusicNowPlayingTool(context: musicContext),
            MusicVolumeTool(context: musicContext),
            OpenApplicationTool(launcher: appLauncher),
            CloseApplicationTool(),
            OpenURLTool(launcher: appLauncher),
            BrowserSearchTool(launcher: appLauncher),
            WebSearchTool(settings: settings),
            TimerSetTool(timers: timers, undo: undo),
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
            CalendarCreateTool(service: calendar, undo: undo),
            CalendarUpdateTool(service: calendar, undo: undo),
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
