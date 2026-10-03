import os
import AppKit
import IVYCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var env: AppEnvironment!
    private var notchController: NotchWindowController!
    private var shortcuts: GlobalShortcutManager!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController!
    private var setupWindow: SetupWindowController!
    private var appliedShortcut: ActivationShortcut?
    private var appliedGesture: GestureConfiguration?
    private var appliedDisplay: String?
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        env = AppEnvironment()
        let env = self.env!

        settingsWindow = SettingsWindowController(env: env)
        setupWindow = SetupWindowController(env: env)
        env.settingsPresenter = { [weak self] section in
            self?.env.notch.moveToWorkspace()
            self?.settingsWindow.show(section: section)
        }

        #if DEBUG
        if CommandLine.arguments.contains("--notch-preview") {
            notchController = NotchWindowController(model: env.notch, settings: env.settings)
            DebugBridge.install(env: env)
            env.notch.isPinnedForDemo = true
            env.notch.presentDemo(query: "Help me polish this sentence.",
                                  answer: "Select editable text, then click the small green button beside it to open IVY's writing tools.",
                                  cards: [], phase: .answered)
            return
        }
        if CommandLine.arguments.contains("--settings-preview") {
            DebugBridge.install(env: env)
            settingsWindow.show(section: "connectors")
            UpdateInstaller.confirmLaunch()
            return
        }
        #endif

        notchController = NotchWindowController(model: env.notch, settings: env.settings)

        shortcuts = GlobalShortcutManager(shortcut: env.settings.activationShortcut,
                                          configuration: env.settings.gestureConfiguration)
        shortcuts.onGesture = { [weak self] event in self?.handle(event) }
        shortcuts.onEscape = { [weak self] in
            guard let notch = self?.env.notch, notch.isOpen else { return }
            notch.dismiss()
        }
        shortcuts.start()
        env.writingAssist.start()
        env.shortcuts = shortcuts
        appliedShortcut = env.settings.activationShortcut
        appliedGesture = env.settings.gestureConfiguration
        appliedDisplay = env.settings.string(.displayPreference)

        statusItem = StatusItemController(env: env) { [weak self] in self?.setupWindow.show() }
        statusItem.setVisible(env.settings.bool(.showMenuBarIcon))

        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }

        #if DEBUG
        DebugBridge.install(env: env)
        #endif

        env.permissions.refresh()
        env.runtime.refresh()
        Task { await env.claudeCode.refreshDetection() }

        if !env.settings.bool(.hasCompletedSetup) {
            setupWindow.show()
        } else if !env.settings.bool(.startMinimized) {
            env.notch.openDashboard()
        }
        UpdateInstaller.confirmLaunch()
        Log.ui.info("IVY launched (shortcut detection: \(self.shortcuts.mode.rawValue, privacy: .public))")
    }

    @objc func showSettings(_ sender: Any?) { env.openSettings() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        env.writingAssist.stop()
        shortcuts?.stop()
        Task {
            await env.llm.unloadModel()
            await env.whisper.unload()
            await env.tts.unload()
        }
    }

    private func handle(_ event: GestureEvent) {
        switch event {
        case .activateVoice:
            notchController.prepareForActivation()
            env.notch.activateVoice()
        case .finishVoice:
            env.notch.finishVoice()
        case .enterTextMode:
            notchController.prepareForActivation()
            env.notch.enterTextMode()
        }
    }

    /// Applies settings changes live (UserDefaults changes fire for every write, so each
    /// step only acts when its value actually changed).
    private func applySettings() {
        let settings = env.settings
        statusItem?.setVisible(settings.bool(.showMenuBarIcon))

        let shortcut = settings.activationShortcut
        let gesture = settings.gestureConfiguration
        if shortcut != appliedShortcut || gesture != appliedGesture {
            appliedShortcut = shortcut
            appliedGesture = gesture
            shortcuts?.update(shortcut: shortcut, configuration: gesture)
        }
        let display = settings.string(.displayPreference)
        if display != appliedDisplay {
            appliedDisplay = display
            notchController?.relayout()
        }
    }
}
