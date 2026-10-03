import os
import AppKit
import Combine
import IVYCore
import OSLog
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case assistant, general, dashboard, ai, writing, benchmark, usage, connectors, routines, history, voice, shortcuts, integrations, privacy, updates, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .writing: return "Writing Assistant"
        case .benchmark: return "Benchmark"
        case .assistant: return "Assistant"
        case .dashboard: return "Dashboard"
        case .usage: return "AI Usage"
        case .connectors: return "App Connectors"
        case .routines: return "Routines"
        case .history: return "History"
        case .updates: return "Updates"
        case .general: return "General"
        case .ai: return "AI"
        case .voice: return "Voice"
        case .shortcuts: return "Shortcuts"
        case .integrations: return "Integrations"
        case .privacy: return "Privacy"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .writing: return "pencil.line"
        case .benchmark: return "checkmark.seal"
        case .assistant: return "bubble.left.and.bubble.right"
        case .dashboard: return "rectangle.3.group"
        case .usage: return "chart.bar"
        case .connectors: return "point.3.connected.trianglepath.dotted"
        case .routines: return "bolt.circle"
        case .history: return "clock.arrow.circlepath"
        case .updates: return "arrow.down.circle"
        case .general: return "gearshape"
        case .ai: return "cpu"
        case .voice: return "waveform"
        case .shortcuts: return "command"
        case .integrations: return "puzzlepiece.extension"
        case .privacy: return "hand.raised"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var section: SettingsSection = .general
}

struct SettingsView: View {
    let env: AppEnvironment
    @ObservedObject var navigation: SettingsNavigation
    @AppStorage(SettingsKey.aiProvider.rawValue) private var activeProvider = AIProvider.local.rawValue
    @AppStorage(SettingsKey.taskModels.rawValue) private var taskModels = "{}"
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: Binding<SettingsSection?>(
                get: { navigation.section }, set: { if let value = $0 { navigation.section = value } })) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
                    .padding(.vertical, 5)
            }
            .scrollContentBackground(.hidden)
            .background(SettingsPalette.sidebar(scheme))
            .navigationTitle("IVY")
            .navigationSplitViewColumnWidth(min: 185, ideal: 210, max: 260)
            VStack(alignment: .leading, spacing: 3) {
                Text("IVY \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")").font(.caption.bold())
                Text("Your Mac. Your assistant.").font(.caption).foregroundStyle(.secondary)
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsPalette.sidebar(scheme))
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(navigation.section.title, systemImage: navigation.section.symbol)
                        .font(.title2.bold())
                    Spacer()
                    Text(commandProvider.displayName).font(.caption).foregroundStyle(.secondary)
                }.padding(24)
                Divider()
                detail
                    .scrollContentBackground(.hidden)
            }
            .background(SettingsPalette.window(scheme))
        }
        .tint(.blue)
        .background(SettingsPalette.window(scheme))
        .frame(minWidth: 820, idealWidth: 1000, minHeight: 620, idealHeight: 740)
    }

    private var commandProvider: AIProvider {
        _ = activeProvider; _ = taskModels
        return env.settings.modelChoice(for: .commands).provider
    }

    @ViewBuilder private var detail: some View {
        switch navigation.section {
        case .assistant: AssistantWorkspace(env: env, model: env.notch)
        case .general: GeneralSettings(env: env)
        case .dashboard: DashboardSettings(env: env)
        case .ai: AISettings(env: env, runtime: env.runtime)
        case .writing: WritingAssistSettings(env: env)
        case .benchmark: BenchmarkSettings(env: env)
        case .usage: UsageSettings(store: env.usage)
        case .connectors: ConnectorSettings(manager: env.connectors)
        case .routines: RoutineSettings(env: env)
        case .history: HistorySettings(env: env, model: env.notch)
        case .voice: VoiceSettings(env: env, runtime: env.runtime)
        case .shortcuts: ShortcutSettings(env: env)
        case .integrations: IntegrationSettings(env: env, permissions: env.permissions, claude: env.claudeCode)
        case .privacy: PrivacySettings(env: env, permissions: env.permissions)
        case .updates: UpdateSettings(updater: env.updater)
        case .advanced: AdvancedSettings(env: env)
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    let env: AppEnvironment
    @AppStorage(SettingsKey.launchAtLogin.rawValue) private var launchAtLogin = false
    @AppStorage(SettingsKey.playActivationSound.rawValue) private var playSound = true
    @AppStorage(SettingsKey.showMenuBarIcon.rawValue) private var showMenuBarIcon = true
    @AppStorage(SettingsKey.startMinimized.rawValue) private var startMinimized = true
    @AppStorage(SettingsKey.openOnHover.rawValue) private var openOnHover = true
    @AppStorage(SettingsKey.showLiveActivity.rawValue) private var liveActivity = true
    @AppStorage(SettingsKey.autoCollapseSeconds.rawValue) private var autoCollapse = 8.0
    @AppStorage(SettingsKey.dismissOnClickOutside.rawValue) private var dismissOnClick = true
    @AppStorage(SettingsKey.displayPreference.rawValue) private var display = "auto"
    @AppStorage(SettingsKey.showGlance.rawValue) private var showGlance = true
    @AppStorage(SettingsKey.proactiveNudges.rawValue) private var nudges = true

    var body: some View {
        Form {
            Section {
                Toggle("Launch IVY at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in LoginItemService.setEnabled(value) }
                Toggle("Play activation sound", isOn: $playSound)
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                Toggle("Start minimized", isOn: $startMinimized)
            }
            Section("Notch") {
                Toggle("Open dashboard when hovering the notch", isOn: $openOnHover)
                Toggle("Show now playing on the closed notch", isOn: $liveActivity)
                Toggle("Show today at a glance on the dashboard", isOn: $showGlance)
                    .onChange(of: showGlance) { _, _ in env.glance.refresh(force: true) }
                Text("Reminders due today, your next event, battery, unread mail and the active Focus, without asking. Only sources you've already allowed are read.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show notices on the notch", isOn: $nudges)
                    .onChange(of: nudges) { _, _ in env.nudges.replan() }
                Text("“Standup in 10 min”, “Battery at 15%”, “Mac is very hot”. Calendar notices stay silent during Sleep and Do Not Disturb.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Display", selection: $display) {
                    Text("Built-in display (notch)").tag("auto")
                    Text("Main display").tag("main")
                    Text("Display with the pointer").tag("mouse")
                }
                LabeledContent("Collapse answers after") {
                    HStack {
                        Slider(value: $autoCollapse, in: 0...30, step: 1).frame(width: 180)
                        Text(autoCollapse == 0 ? "Never" : "\(Int(autoCollapse)) s").monospacedDigit().frame(width: 50)
                    }
                }
                Toggle("Close when clicking outside", isOn: $dismissOnClick)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI

struct AISettings: View {
    let env: AppEnvironment
    @ObservedObject var runtime: RuntimeManager
    @AppStorage(SettingsKey.llmModelID.rawValue) private var modelID = ModelCatalog.defaultLLM.id
    @AppStorage(SettingsKey.llmModelPath.rawValue) private var modelPath = ""
    @AppStorage(SettingsKey.cloudMaxResponseTokens.rawValue) private var cloudMaxTokens = 2048
    @AppStorage(SettingsKey.aiProvider.rawValue) private var providerID = AIProvider.local.rawValue
    @AppStorage(SettingsKey.writingModelID.rawValue) private var writingModelID = ""
    @AppStorage(SettingsKey.writingProvider.rawValue) private var writingProvider = "same"
    @AppStorage(SettingsKey.contextLength.rawValue) private var contextLength = 8192
    @AppStorage(SettingsKey.temperature.rawValue) private var temperature = 0.3
    @AppStorage(SettingsKey.maxResponseTokens.rawValue) private var maxTokens = 320
    @AppStorage(SettingsKey.unloadAfterMinutes.rawValue) private var unloadMinutes = 15
    @AppStorage(SettingsKey.fastCommandRouting.rawValue) private var fastRouting = true
    @AppStorage(SettingsKey.energyAwareModels.rawValue) private var energyAware = true
    @AppStorage(SettingsKey.focusAwareReplies.rawValue) private var focusAware = true

    var body: some View {
        Form {
            TaskModelSettings(env: env)
            Section("AI provider") {
                Picker("Use", selection: $providerID) {
                    ForEach(AIProvider.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .onChange(of: providerID) { _, _ in
                    guard !env.notch.isBusy else { return }
                    Task {
                        await env.llm.unloadModel()
                        await env.writerLLM.unloadModel()
                    }
                }
                Text("Local runs on your Mac. Cloud sends your requests, recent conversation and tool results (including requested clipboard, mail or calendar data) to the selected provider. API usage is billed to your account. Speech recognition and TTS stay local.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(AIProvider.allCases.filter { $0 != .local }) { provider in
                CloudProviderSettings(provider: provider, usage: env.usage).id(provider)
            }
            if providerID == AIProvider.local.rawValue {
                RuntimeSection(runtime: runtime)
                Section("Local model") {
                    Picker("Model", selection: $modelID) {
                        ForEach(ModelCatalog.llms) { model in
                            Text("\(model.displayName) · \(model.formattedSize)").tag(model.id)
                        }
                    }
                    .onChange(of: modelID) { _, _ in Task { await env.llm.unloadModel() } }
                    if let model = ModelCatalog.descriptor(id: modelID) {
                        ModelRow(model: model, runtime: runtime)
                    }
                    TextField("Custom model path", text: $modelPath, prompt: Text("Optional MLX model folder"))
                    Text("IVY runs \(ModelCatalog.descriptor(id: modelID)?.displayName ?? "the model") with MLX-LM on your Mac. A custom path overrides the selection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Writing model") {
                    Picker("Write answers with", selection: $writingModelID) {
                        Text("Same as the main model").tag("")
                        ForEach(ModelCatalog.llms) { model in
                            Text("\(model.displayName) · \(model.formattedSize)").tag(model.id)
                        }
                    }
                    .onChange(of: writingModelID) { _, _ in Task { await env.writerLLM.unloadModel() } }
                    if let model = ModelCatalog.descriptor(id: writingModelID) {
                        ModelRow(model: model, runtime: runtime)
                    }
                    Text("Optional. The main model stays in charge of commands and picking tools, which keeps IVY fast; web answers, clipboard rewrites, definitions and synonyms are written by this model instead. For example, Qwen3 4B for commands and Qwen3 14B for writing. Both stay in memory while in use.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Writing & hybrid routing") {
                Picker("Answer provider", selection: $writingProvider) {
                    Text("Same as command provider").tag("same")
                    ForEach(AIProvider.allCases.filter { $0 != .local }) { Text($0.displayName).tag($0.rawValue) }
                }
                Text("Choosing Local for commands and a cloud answer provider creates hybrid routing: local tools and command selection, cloud writing for web answers and text transforms. Each cloud provider uses its saved model and API key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DownloadedModelsSection(runtime: runtime)
            Section("Generation") {
                if providerID == AIProvider.local.rawValue {
                    Picker("Context length", selection: $contextLength) {
                        ForEach([4096, 8192, 16384, 32768], id: \.self) { Text("\($0) tokens").tag($0) }
                    }
                    LabeledContent("Temperature") {
                        HStack {
                            Slider(value: $temperature, in: 0...1, step: 0.05).frame(width: 180)
                            Text(String(format: "%.2f", temperature)).monospacedDigit().frame(width: 40)
                        }
                    }
                }
                if providerID == AIProvider.local.rawValue {
                    Stepper("Maximum response length: \(maxTokens) tokens", value: $maxTokens, in: 64...2048, step: 32)
                } else {
                    Stepper("Output budget: \(max(2048, cloudMaxTokens)) tokens", value: Binding(
                        get: { max(2048, cloudMaxTokens) }, set: { cloudMaxTokens = $0 }), in: 2048...32768, step: 512)
                    Text("Cloud output includes reasoning and tool arguments. Text streams as it arrives; tools execute only after a complete validated response.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if providerID == AIProvider.local.rawValue {
                    Picker("Unload model after inactivity", selection: $unloadMinutes) {
                        Text("Never").tag(0)
                        ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                }
                Toggle("Instant commands (skip the model for simple commands)", isOn: $fastRouting)
                Toggle("Adapt replies to the active Focus", isOn: $focusAware)
            }
            if providerID == AIProvider.local.rawValue {
                EnergySection(env: env, energy: env.energy, energyAware: $energyAware)
            }
        }
        .formStyle(.grouped)
        .onAppear { runtime.refresh() }
    }
}

struct EnergySection: View {
    let env: AppEnvironment
    @ObservedObject var energy: EnergyMonitor
    @Binding var energyAware: Bool

    var body: some View {
        Section("Energy") {
            Toggle("Energy-aware model loading", isOn: $energyAware)
                .onChange(of: energyAware) { _, _ in env.applyEnergyPolicy(energy.policy) }
            Text("When your Mac runs hot, is in Low Power Mode or is low on battery, IVY unloads idle models sooner, and right away when it's critical.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Now") {
                Text("\(energy.snapshot.thermal.displayName) · \(energy.policy.description)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RuntimeSection: View {
    @ObservedObject var runtime: RuntimeManager
    @State private var showLog = false

    var body: some View {
        Section("Local AI runtime") {
            HStack {
                statusLabel
                Spacer()
                switch runtime.runtimeStatus {
                case .missing, .failed:
                    Button("Install Runtime") { runtime.installRuntime() }
                case .installing:
                    ProgressView().controlSize(.small)
                default:
                    Button("Check") { runtime.refresh() }
                }
            }
            if !runtime.packageVersions.isEmpty {
                Text(["mlx", "mlx_lm", "mlx_whisper", "mlx_audio"].compactMap { name in
                    runtime.packageVersions[name].map { "\(name) \($0)" }
                }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            }
            if !runtime.installLog.isEmpty {
                DisclosureGroup("Installer log", isExpanded: $showLog) {
                    ScrollView {
                        Text(runtime.installLog.suffix(80).joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 120)
                }
            }
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch runtime.runtimeStatus {
        case .unknown: Label("Checking…", systemImage: "hourglass")
        case .missing: Label("Not installed (Python + MLX, ~1.5 GB)", systemImage: "xmark.circle").foregroundStyle(.orange)
        case .installing(let step): Label(step, systemImage: "arrow.down.circle")
        case .ready: Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }
}

/// Install / progress / delete controls for one model.
struct ModelRow: View {
    let model: ModelDescriptor
    @ObservedObject var runtime: RuntimeManager
    @State private var confirmDelete = false

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                Text("\(model.repo) · \(model.formattedSize)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch runtime.state(for: model) {
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
                Menu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.directory(in: SettingsStore().modelsFolder)])
                    }
                    Button("Delete Model…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .modelDeleteConfirmation(model, runtime: runtime, isPresented: $confirmDelete)
            case .downloading(let progress, let bytes, let total):
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: progress).frame(width: 140)
                    Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button { runtime.cancelDownload(model) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
            case .notInstalled, .failed:
                if case .failed(let message) = runtime.state(for: model) {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Button("Download") { runtime.download(model) }
                    .disabled(!RuntimeManager.isRuntimeInstalled)
                    .help(RuntimeManager.isRuntimeInstalled ? "Needs \(model.formattedSize) of disk space"
                          : "Install the runtime first")
            }
        }
    }
}

/// Every downloaded model with its size on disk, so space can be freed from IVY itself.
struct DownloadedModelsSection: View {
    @ObservedObject var runtime: RuntimeManager
    @State private var pendingDelete: ModelDescriptor?
    @State private var confirmDeleteAll = false

    private var totalBytes: Int64 { runtime.installedModels.reduce(0) { $0 + runtime.size(of: $1) } }

    var body: some View {
        Section {
            if runtime.installedModels.isEmpty {
                Text("No models downloaded.").foregroundStyle(.secondary)
            }
            ForEach(runtime.installedModels) { model in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName)
                        Text("\(model.kind.title) · \(ByteCountFormatter.string(fromByteCount: runtime.size(of: model), countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { pendingDelete = model } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            if runtime.installedModels.count > 1 {
                HStack {
                    Spacer()
                    Button("Delete All Models…", role: .destructive) { confirmDeleteAll = true }
                }
            }
        } header: {
            HStack {
                Text("Downloaded models")
                Spacer()
                if totalBytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Deleted models are removed from your Mac. You can download them again at any time.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .modelDeleteConfirmation(pendingDelete, runtime: runtime, isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }))
        .confirmationDialog("Delete all downloaded models?", isPresented: $confirmDeleteAll) {
            Button("Delete All (\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)))", role: .destructive) {
                Task { await runtime.deleteAllModels() }
            }
        } message: {
            Text("Local AI needs its models downloaded again. Cloud AI remains available when configured.")
        }
    }
}

extension View {
    /// Asks before removing a model's files from disk.
    func modelDeleteConfirmation(_ model: ModelDescriptor?, runtime: RuntimeManager, isPresented: Binding<Bool>) -> some View {
        confirmationDialog("Delete \(model?.displayName ?? "model")?", isPresented: isPresented, presenting: model) { model in
            Button("Delete (\(ByteCountFormatter.string(fromByteCount: runtime.size(of: model), countStyle: .file)))", role: .destructive) {
                Task { await runtime.delete(model) }
            }
        } message: { _ in
            Text("The model files are removed from your Mac. You can download it again later.")
        }
    }
}

private extension ModelKind {
    var title: String {
        switch self {
        case .llm: return "Language model"
        case .whisper: return "Speech recognition"
        case .kokoro: return "Voice"
        }
    }
}

// MARK: - Voice

struct VoiceSettings: View {
    let env: AppEnvironment
    @ObservedObject var runtime: RuntimeManager
    @AppStorage(SettingsKey.speechModelID.rawValue) private var speechModel = ModelCatalog.defaultWhisper.id
    @AppStorage(SettingsKey.speechLanguage.rawValue) private var language = "auto"
    @AppStorage(SettingsKey.ttsEnabled.rawValue) private var ttsEnabled = false
    @AppStorage(SettingsKey.kokoroVoice.rawValue) private var voice = "af_heart"
    @AppStorage(SettingsKey.speechRate.rawValue) private var rate = 1.0
    @AppStorage(SettingsKey.ttsVolume.rawValue) private var volume = 0.9
    @AppStorage(SettingsKey.quietDuringFocus.rawValue) private var quietDuringFocus = true
    @State private var testing = false

    var body: some View {
        Form {
            Section("Speech recognition (MLX Whisper)") {
                Picker("Model", selection: $speechModel) {
                    ForEach(ModelCatalog.whispers) { Text("\($0.displayName) · \($0.formattedSize)").tag($0.id) }
                }
                .onChange(of: speechModel) { _, _ in Task { await env.whisper.unload() } }
                if let model = ModelCatalog.descriptor(id: speechModel) { ModelRow(model: model, runtime: runtime) }
                Picker("Language", selection: $language) {
                    Text("Detect automatically").tag("auto")
                    ForEach([("en", "English"), ("de", "German"), ("fr", "French"), ("es", "Spanish"), ("it", "Italian"),
                             ("nl", "Dutch"), ("pt", "Portuguese"), ("ja", "Japanese"), ("zh", "Chinese")], id: \.0) {
                        Text($0.1).tag($0.0)
                    }
                }
            }
            Section("Voice responses (Kokoro + MLX)") {
                Toggle("Voice responses", isOn: $ttsEnabled)
                Toggle("Stay quiet during Sleep and Do Not Disturb", isOn: $quietDuringFocus)
                Text("When on, IVY speaks its answers with Kokoro running locally on MLX. Off by default.")
                    .font(.caption).foregroundStyle(.secondary)
                ModelRow(model: ModelCatalog.kokoro, runtime: runtime)
                Picker("Kokoro voice", selection: $voice) {
                    ForEach(ModelCatalog.kokoroVoices, id: \.id) { Text($0.name).tag($0.id) }
                }
                LabeledContent("Speech rate") {
                    HStack {
                        Slider(value: $rate, in: 0.6...1.6, step: 0.05).frame(width: 180)
                        Text(String(format: "%.2f×", rate)).monospacedDigit().frame(width: 50)
                    }
                }
                LabeledContent("Volume") {
                    Slider(value: $volume, in: 0...1).frame(width: 230)
                }
                HStack {
                    Button(testing ? "Speaking…" : "Test Voice") {
                        testing = true
                        Task {
                            try? await env.tts.speak("Hi, I'm IVY. I run entirely on your Mac.")
                            testing = false
                        }
                    }
                    .disabled(testing || !env.tts.isAvailable)
                    if !env.tts.isAvailable {
                        Text("Download Kokoro to enable voice.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

struct ShortcutSettings: View {
    let env: AppEnvironment
    @AppStorage(SettingsKey.activationShortcut.rawValue) private var shortcut = ActivationShortcut.commandOption.rawValue
    @AppStorage(SettingsKey.holdDuration.rawValue) private var hold = 0.5
    @AppStorage(SettingsKey.textToggleWindow.rawValue) private var toggleWindow = 0.5

    var body: some View {
        let current = ActivationShortcut(rawValue: shortcut) ?? .commandOption
        Form {
            Section("Activation") {
                Picker("Shortcut", selection: $shortcut) {
                    ForEach(ActivationShortcut.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                }
                LabeledContent("Current shortcut") {
                    Text("Hold \(current.symbols)").font(.system(.body, design: .rounded).weight(.semibold))
                }
                LabeledContent("Hold duration") {
                    HStack {
                        Slider(value: $hold, in: 0.3...2.0, step: 0.1).frame(width: 180)
                        Text(String(format: "%.1f s", hold)).monospacedDigit().frame(width: 50)
                    }
                }
                LabeledContent("Text-mode window") {
                    HStack {
                        Slider(value: $toggleWindow, in: 0.25...1.0, step: 0.05).frame(width: 180)
                        Text(String(format: "%.2f s", toggleWindow)).monospacedDigit().frame(width: 50)
                    }
                }
            }
            Section("How it works") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Voice: hold \(current.symbols) for \(String(format: "%.1f", hold)) s, speak, release.", systemImage: "mic")
                    Label("Text: hold \(current.symbols), release \(current.primarySymbol), press \(current.primarySymbol) again.", systemImage: "keyboard")
                    Label("Esc closes IVY. Hover the notch for the dashboard.", systemImage: "escape")
                }
                .font(.callout)
                LabeledContent("Detection") {
                    Text(env.shortcuts?.mode.rawValue ?? "—").foregroundStyle(.secondary)
                }
                if !CGPreflightListenEventAccess() {
                    HStack {
                        Text("Grant Input Monitoring for the most reliable, zero-overhead detection.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Grant…") { env.permissions.requestInputMonitoring(); env.permissions.open(.inputMonitoring) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Integrations

struct IntegrationSettings: View {
    let env: AppEnvironment
    @ObservedObject var permissions: PermissionService
    @ObservedObject var claude: ClaudeCodeService
    @AppStorage(SettingsKey.onlineTrackLookup.rawValue) private var onlineLookup = true
    @AppStorage(SettingsKey.codingSessionMode.rawValue) private var sessionMode = CodingSessionInfo.Mode.terminal.rawValue
    @AppStorage(SettingsKey.webSearchEnabled.rawValue) private var webSearch = true
    @AppStorage(SettingsKey.spotifyClientID.rawValue) private var spotifyClientID = ""
    @State private var spotifySecret = Keychain.read(account: SpotifyCredentials.keychainAccount) ?? ""
    @AppStorage(SettingsKey.codingProjectsFolder.rawValue) private var projectsFolder = "~/IVY Projects"
    @AppStorage(SettingsKey.mailOnDashboard.rawValue) private var mailOnDashboard = true
    @State private var shortcutCount: Int?

    var body: some View {
        Form {
            Section("Reminders") {
                StatusRow(title: "Access", status: permissions.reminders)
                if permissions.reminders == .notDetermined {
                    Button("Allow Access to Reminders") { Task { await permissions.requestReminders(using: env.reminders) } }
                }
            }
            Section("Spotify") {
                LabeledContent("Spotify app") {
                    Text(env.spotify.isInstalled ? (env.spotify.isRunning ? "Installed · running" : "Installed") : "Not installed")
                        .foregroundStyle(env.spotify.isInstalled ? Color.primary : Color.orange)
                }
                StatusRow(title: "Automation permission", status: permissions.spotifyAutomation)
                Toggle("Find songs online (iTunes Search + song.link)", isOn: $onlineLookup)
                Text("Turns “Play Billie Jean” into a Spotify track using public catalogs (Deezer, iTunes, ListenBrainz). Only the song name is sent. When off, IVY opens Spotify's search instead.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Spotify client ID (optional)", text: $spotifyClientID)
                SecureField("Spotify client secret (optional)", text: $spotifySecret)
                    .onSubmit { Keychain.write(spotifySecret, account: SpotifyCredentials.keychainAccount) }
                    .onChange(of: spotifySecret) { _, value in Keychain.write(value, account: SpotifyCredentials.keychainAccount) }
                HStack {
                    Text("For the most accurate song matching, create a free app at developer.spotify.com and paste its credentials. The secret is stored in your Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Open Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!).font(.caption)
                }
            }
            Section("Mail") {
                LabeledContent("Apple Mail") {
                    Text(env.mail.isInstalled ? (env.mail.isRunning ? "Installed · running" : "Installed") : "Not installed")
                        .foregroundStyle(env.mail.isInstalled ? Color.primary : Color.orange)
                }
                StatusRow(title: "Automation permission", status: permissions.mailAutomation)
                Toggle("Show unread mail on the dashboard", isOn: $mailOnDashboard)
                Text("Ask “Any new mail from Alex?” or “Search for invoice in my inbox”. IVY reads only the sender, subject and date of recent inbox messages, never message bodies, and only when you ask. The dashboard count is only shown while Mail is open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Home, Focus & Shortcuts") {
                LabeledContent("Shortcuts") {
                    Text(shortcutCount.map { "\($0) found" } ?? "…").foregroundStyle(.secondary)
                }
                Text("macOS apps can't control HomeKit or switch Focus directly, so IVY runs your own Shortcuts. Create shortcuts in the Shortcuts app for your scenes and devices (“Lights”, “Thermostat”), then say “Lights to 50%” and IVY passes 50 as the shortcut's input. For Focus, name them “Work Focus”, “Sleep Focus” and “Focus Off” using the Set Focus action. Shortcuts that unlock, open doors or send messages always ask first.")
                    .font(.caption).foregroundStyle(.secondary)
                StatusRow(title: "Read the active Focus (Full Disk Access)", status: env.focus.current(maxAge: 0) == .unavailable ? .notDetermined : .granted)
                HStack {
                    Button("Open Shortcuts") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                    Button("Reload") { Task { shortcutCount = await env.shortcutsService.list(refresh: true).count } }
                    Button("Grant Full Disk Access…") { permissions.open(.fullDiskAccess) }
                }
            }
            Section("Web") {
                Toggle("Allow web search and weather", isOn: $webSearch)
                Text("When IVY doesn't know something or needs current information, it searches DuckDuckGo (or Wikipedia) in the background and answers from the results. Weather comes from Open-Meteo. Only the query is sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Coding agents") {
                ForEach(ClaudeCodeService.Agent.allCases, id: \.self) { agent in
                    LabeledContent(agent.displayName) {
                        if let url = claude.detected[agent] {
                            Text((url.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        } else {
                            Text("Not detected").foregroundStyle(.orange)
                        }
                    }
                }
                Picker("Tasks run", selection: $sessionMode) {
                    Text("Interactively in Terminal").tag(CodingSessionInfo.Mode.terminal.rawValue)
                    Text("In the background (result pops up on the notch)").tag(CodingSessionInfo.Mode.background.rawValue)
                }
                Text("“Open Claude Code” always opens an interactive session in Terminal. Background tasks need the CLI to be logged in.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Projects folder", text: $projectsFolder)
                Button("Detect Again") { Task { await claude.refreshDetection() } }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            permissions.refresh()
            Task { await claude.refreshDetection() }
            Task { shortcutCount = await env.shortcutsService.list().count }
        }
    }
}

struct StatusRow: View {
    let title: String
    let status: PermissionService.Status

    var body: some View {
        LabeledContent(title) {
            Label(status.label, systemImage: icon).foregroundStyle(color)
        }
    }

    private var icon: String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle"
        case .notApplicable: return "minus.circle"
        }
    }

    private var color: Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        case .notApplicable: return .secondary
        }
    }
}

// MARK: - Privacy

struct PrivacySettings: View {
    let env: AppEnvironment
    @ObservedObject var permissions: PermissionService

    var body: some View {
        Form {
            Section("Permissions") {
                permissionRow("Microphone", permissions.microphone, pane: .microphone) {
                    Task { _ = await permissions.requestMicrophone() }
                }
                permissionRow("Reminders", permissions.reminders, pane: .reminders) {
                    Task { await permissions.requestReminders(using: env.reminders) }
                }
                permissionRow("Input Monitoring (shortcut)", permissions.inputMonitoring, pane: .inputMonitoring) {
                    permissions.requestInputMonitoring()
                }
                permissionRow("Automation (Spotify)", permissions.spotifyAutomation, pane: .automation, request: nil)
                permissionRow("Accessibility", permissions.accessibility, pane: .accessibility, request: nil)
                Text("Accessibility enables selected-text context and the writing assistant's field replacement. It is optional for other features. The main shortcut uses Input Monitoring or the modifier state.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Local by default") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Speech recognition and TTS run on this Mac. Local AI is the default; cloud AI is optional in Settings ▸ AI.", systemImage: "lock.laptopcomputer")
                    Label("Microphone audio is kept in memory and deleted right after transcription.", systemImage: "mic.slash")
                    Label("No analytics or telemetry. With cloud AI, requests, recent conversation and tool results go to your selected provider.", systemImage: "eye.slash")
                    Label("Network is used for model downloads, optional cloud AI, song lookup, web search, weather and Spotify/Claude Code.", systemImage: "network")
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }

    private func permissionRow(_ title: String, _ status: PermissionService.Status, pane: PermissionService.Pane,
                               request: (() -> Void)?) -> some View {
        HStack {
            StatusRow(title: title, status: status)
            if status == .notDetermined, let request {
                Button("Request", action: request)
            }
            Button("Open…") { permissions.open(pane) }
        }
    }
}

// MARK: - Advanced

/// What IVY learned from corrections ("nicht stören" → Focus). Each entry can be removed.
struct LearnedPhrasesSection: View {
    let phrases: PhraseMemory
    @State private var entries: [PhraseMemory.Entry] = []

    var body: some View {
        Section {
            if entries.isEmpty {
                Text("Nothing learned yet. When a request doesn't work and you rephrase it, IVY remembers what you meant.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("“\(entry.phrase)”")
                        Text(Self.describe(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        phrases.forget(entry.phrase)
                        entries = phrases.all
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Forget")
                }
            }
            if entries.count > 1 {
                Button("Forget All", role: .destructive) {
                    phrases.clear()
                    entries = []
                }
            }
        } header: {
            Text("Learned phrases")
        }
        .onAppear { entries = phrases.all }
    }

    static func describe(_ entry: PhraseMemory.Entry) -> String {
        let arguments = entry.arguments.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.stringValue ?? $0.value.jsonString())" }
            .joined(separator: ", ")
        return arguments.isEmpty ? entry.toolName : "\(entry.toolName) (\(arguments))"
    }
}

struct AdvancedSettings: View {
    let env: AppEnvironment
    @AppStorage(SettingsKey.saveHistory.rawValue) private var saveHistory = true
    @AppStorage(SettingsKey.modelsFolder.rawValue) private var modelsFolder = ""
    @State private var confirmReset = false
    @State private var exportMessage: String?

    var body: some View {
        Form {
            Section("Models") {
                LabeledContent("Model folder") {
                    Text((env.settings.modelsFolder.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                TextField("Custom model folder", text: $modelsFolder, prompt: Text("Default: Application Support/IVY/Models"))
                HStack {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: env.settings.modelsFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(env.settings.modelsFolder)
                    }
                    Button("Unload Models Now") {
                        Task {
                            await env.llm.unloadModel()
                            await env.whisper.unload()
                            await env.tts.unload()
                        }
                    }
                }
            }
            LearnedPhrasesSection(phrases: env.phrases)
            Section("History") {
                Toggle("Keep a local history of requests", isOn: $saveHistory)
                Button("Clear Conversation History", role: .destructive) {
                    env.notch.clearHistory()
                    Task { await env.agent.resetConversation() }
                }
            }
            Section("Diagnostics") {
                HStack {
                    Button("Show Logs") { exportLogs() }
                    if let exportMessage { Text(exportMessage).font(.caption).foregroundStyle(.secondary) }
                }
                Button("Reset All Settings…", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all IVY settings to their defaults?", isPresented: $confirmReset) {
            Button("Reset Settings", role: .destructive) { env.settings.reset() }
        }
    }

    /// Writes this session's IVY log entries to a file and reveals it. Prompts are
    /// redacted in logs by default.
    private func exportLogs() {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(timeIntervalSinceLatestBoot: 0)
            let entries = try store.getEntries(at: position,
                                               matching: NSPredicate(format: "subsystem == %@", Log.subsystem))
            let formatter = ISO8601DateFormatter()
            let lines = entries.compactMap { $0 as? OSLogEntryLog }.map {
                "\(formatter.string(from: $0.date)) [\($0.category)] \($0.composedMessage)"
            }
            try FileManager.default.createDirectory(at: AppPaths.logsFolder, withIntermediateDirectories: true)
            let file = AppPaths.logsFolder.appendingPathComponent("ivy-\(Int(Date().timeIntervalSince1970)).log")
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([file])
            exportMessage = "\(lines.count) entries exported"
        } catch {
            exportMessage = error.localizedDescription
        }
    }
}

// MARK: - Window

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let env: AppEnvironment
    private let navigation = SettingsNavigation()

    init(env: AppEnvironment) {
        self.env = env
        super.init()
    }

    func show(section: String? = nil) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier { env.selectionApplication = frontmost }
        if let section, let target = SettingsSection(rawValue: section) { navigation.section = target }
        if navigation.section == .assistant { env.notch.moveToWorkspace() }
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(env: env, navigation: navigation))
            let window = NSWindow(contentViewController: controller)
            window.title = "IVY Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1000, height: 740))
            window.contentMinSize = NSSize(width: 820, height: 620)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("IVYSettings")
            self.window = window
        }
        env.permissions.refresh()
        env.runtime.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { env.notch.workspaceVisible = false }
}
