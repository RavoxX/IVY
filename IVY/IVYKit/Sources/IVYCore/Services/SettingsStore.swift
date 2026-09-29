import Foundation

/// UserDefaults keys. SwiftUI views bind to the same keys with `@AppStorage`.
public enum SettingsKey: String, CaseIterable, Sendable {
    // General
    case launchAtLogin = "general.launchAtLogin"
    case playActivationSound = "general.playActivationSound"
    case showMenuBarIcon = "general.showMenuBarIcon"
    case startMinimized = "general.startMinimized"
    case autoCollapseSeconds = "general.autoCollapseSeconds"
    case dismissOnClickOutside = "general.dismissOnClickOutside"
    case paused = "general.paused"
    case hasCompletedSetup = "general.hasCompletedSetup"
    case openOnHover = "general.openOnHover"
    case showLiveActivity = "general.showLiveActivity"
    case displayPreference = "general.displayPreference"
    case showGlance = "general.showGlance"
    case proactiveNudges = "general.proactiveNudges"

    // AI
    case llmModelID = "ai.modelID"
    case llmModelPath = "ai.modelPath"
    case contextLength = "ai.contextLength"
    case temperature = "ai.temperature"
    case maxResponseTokens = "ai.maxResponseTokens"
    case unloadAfterMinutes = "ai.unloadAfterMinutes"
    case fastCommandRouting = "ai.fastCommandRouting"
    case energyAwareModels = "ai.energyAwareModels"
    case writingModelID = "ai.writingModelID"
    case focusAwareReplies = "ai.focusAwareReplies"

    // Voice
    case speechModelID = "voice.speechModelID"
    case speechLanguage = "voice.language"
    case ttsEnabled = "voice.ttsEnabled"
    case kokoroVoice = "voice.kokoroVoice"
    case speechRate = "voice.speechRate"
    case ttsVolume = "voice.ttsVolume"
    case quietDuringFocus = "voice.quietDuringFocus"

    // Shortcuts
    case activationShortcut = "shortcut.activation"
    case holdDuration = "shortcut.holdDuration"
    case textToggleWindow = "shortcut.textToggleWindow"

    // Integrations
    case codingSessionMode = "integrations.codingSessionMode"
    case codingProjectsFolder = "integrations.codingProjectsFolder"
    case spotifyClientID = "integrations.spotifyClientID"
    case onlineTrackLookup = "integrations.onlineTrackLookup"
    case webSearchEnabled = "integrations.webSearchEnabled"
    case mailOnDashboard = "integrations.mailOnDashboard"

    // Advanced
    case modelsFolder = "advanced.modelsFolder"
    case saveHistory = "advanced.saveHistory"
    case logPrompts = "advanced.logPrompts"
}

/// Typed access to IVY's persistent settings with defaults registered in one place.
/// Multi-gigabyte models are never stored here — only paths and identifiers.
public final class SettingsStore: @unchecked Sendable {
    public let defaults: UserDefaults

    public static let defaultValues: [SettingsKey: Any] = [
        .launchAtLogin: false,
        .playActivationSound: true,
        .showMenuBarIcon: true,
        .startMinimized: true,
        .autoCollapseSeconds: 8.0,
        .dismissOnClickOutside: true,
        .paused: false,
        .hasCompletedSetup: false,
        .openOnHover: true,
        .showLiveActivity: true,
        .displayPreference: "auto",
        .showGlance: true,
        .proactiveNudges: true,
        .llmModelID: ModelCatalog.defaultLLM.id,
        .llmModelPath: "",
        .contextLength: 8192,
        .temperature: 0.3,
        .maxResponseTokens: 320,
        .unloadAfterMinutes: 15,
        .fastCommandRouting: true,
        .energyAwareModels: true,
        .writingModelID: "",
        .focusAwareReplies: true,
        .speechModelID: ModelCatalog.defaultWhisper.id,
        .speechLanguage: "auto",
        .ttsEnabled: false, // Voice responses are OFF by default.
        .kokoroVoice: "af_heart",
        .speechRate: 1.0,
        .ttsVolume: 0.9,
        .quietDuringFocus: true,
        .activationShortcut: ActivationShortcut.commandOption.rawValue,
        .holdDuration: 0.5,
        .textToggleWindow: 0.5,
        .codingSessionMode: CodingSessionInfo.Mode.terminal.rawValue,
        .codingProjectsFolder: "~/IVY Projects",
        .spotifyClientID: "",
        .onlineTrackLookup: true,
        .webSearchEnabled: true,
        .mailOnDashboard: true,
        .modelsFolder: "",
        .saveHistory: true,
        .logPrompts: false,
    ]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    public func registerDefaults() {
        var dict: [String: Any] = [:]
        for (key, value) in Self.defaultValues { dict[key.rawValue] = value }
        defaults.register(defaults: dict)
    }

    public func bool(_ key: SettingsKey) -> Bool { defaults.bool(forKey: key.rawValue) }
    public func double(_ key: SettingsKey) -> Double { defaults.double(forKey: key.rawValue) }
    public func int(_ key: SettingsKey) -> Int { defaults.integer(forKey: key.rawValue) }
    public func string(_ key: SettingsKey) -> String { defaults.string(forKey: key.rawValue) ?? "" }

    public func set(_ value: Any?, for key: SettingsKey) {
        defaults.set(value, forKey: key.rawValue)
    }

    /// Removes every stored value, falling back to registered defaults. Setup state is kept.
    public func reset(keepSetupState: Bool = true) {
        let setup = bool(.hasCompletedSetup)
        for key in SettingsKey.allCases { defaults.removeObject(forKey: key.rawValue) }
        if keepSetupState { set(setup, for: .hasCompletedSetup) }
    }

    // MARK: Typed conveniences

    public var ttsEnabled: Bool {
        get { bool(.ttsEnabled) }
        set { set(newValue, for: .ttsEnabled) }
    }

    public var activationShortcut: ActivationShortcut {
        get { ActivationShortcut(rawValue: string(.activationShortcut)) ?? .commandOption }
        set { set(newValue.rawValue, for: .activationShortcut) }
    }

    public var gestureConfiguration: GestureConfiguration {
        GestureConfiguration(holdDuration: max(0.3, double(.holdDuration)),
                             textToggleWindow: max(0.2, double(.textToggleWindow)))
    }

    public var codingSessionMode: CodingSessionInfo.Mode {
        CodingSessionInfo.Mode(rawValue: string(.codingSessionMode)) ?? .terminal
    }

    public var generationOptions: GenerationOptions {
        GenerationOptions(maxTokens: max(32, int(.maxResponseTokens)),
                          temperature: double(.temperature),
                          contextLength: max(2048, int(.contextLength)))
    }

    /// `~/Library/Application Support/IVY/Models` unless overridden.
    public var modelsFolder: URL {
        let custom = string(.modelsFolder)
        if !custom.isEmpty { return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath) }
        return AppPaths.applicationSupport.appendingPathComponent("Models", isDirectory: true)
    }
}

/// File-system locations used by IVY.
public enum AppPaths {
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("IVY", isDirectory: true)
    }

    public static var runtime: URL { applicationSupport.appendingPathComponent("Runtime", isDirectory: true) }
    public static var pythonExecutable: URL { runtime.appendingPathComponent("venv/bin/python3") }
    public static var historyFile: URL { applicationSupport.appendingPathComponent("history.json") }
    public static var logsFolder: URL { applicationSupport.appendingPathComponent("Logs", isDirectory: true) }
    /// Scratch space for transient audio. Files are deleted immediately after use.
    public static var temporary: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("IVY", isDirectory: true)
    }
}
