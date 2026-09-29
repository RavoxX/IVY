import os
import AppKit
import AVFoundation
import Combine
import IVYCore
import SwiftUI

/// Main-actor state for the notch overlay. Owns the interaction flow:
/// gesture → listen/type → transcribe → agent → cards → (optional) speech → collapse.
@MainActor
final class NotchViewModel: ObservableObject {
    // MARK: Published UI state
    @Published private(set) var mode: NotchMode = .closed
    @Published var tab: DashboardTab = .home
    @Published private(set) var phase: AssistantPhase = .answered
    @Published private(set) var query = ""
    @Published private(set) var answer = ""
    @Published private(set) var cards: [ResultCard] = []
    @Published private(set) var workingLabel: String?
    @Published private(set) var workingDone = false
    @Published private(set) var confirmation: ConfirmationRequest?
    @Published private(set) var audioLevel: Float = 0
    @Published var typedText = ""
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var geometry = NotchGeometry(screenFrame: .zero, hasNotch: false, notchWidth: 0,
                                                         topBandHeight: 32, centerX: 0)
    @Published var assistantBodyHeight: CGFloat = 60
    @Published var isHovering = false
    @Published var isDropTargeted = false
    @Published private(set) var errorAction: ErrorAction?

    enum ErrorAction: Equatable { case openSettings(String?), openPrivacy(PermissionService.Pane) }

    // MARK: Dependencies
    let env: AppEnvironment
    private var settings: SettingsStore { env.settings }
    private let capture = AudioCaptureService()
    private var runTask: Task<Void, Never>?
    private var runID = UUID()
    private var speakTask: Task<Void, Never>?
    private var collapseWork: DispatchWorkItem?
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    private var cancellables: Set<AnyCancellable> = []

    /// Set by the window controller; asks the panel to take/release keyboard focus.
    var onKeyFocusChange: ((Bool) -> Void)?

    init(env: AppEnvironment) {
        self.env = env
        capture.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in self?.audioLevel = level }
        }
        // Re-render when playback changes so the live activity appears/disappears.
        env.music.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        env.timers.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        env.claudeCode.onSessionFinished = { [weak self] info in self?.showSessionResult(info) }
        env.timers.onFire = { [weak self] timer in self?.showTimerFinished(timer) }
        Task { await reloadHistory() }
    }

    // MARK: - Geometry

    func updateGeometry(_ geometry: NotchGeometry) {
        self.geometry = geometry
    }

    var showsLiveActivity: Bool {
        !env.timers.timers.isEmpty || (settings.bool(.showLiveActivity) && env.music.isPlaying)
    }

    /// Width the content is laid out at (the shape reveals it while animating).
    var contentWidth: CGFloat {
        switch mode {
        case .closed: return shapeSize.width
        case .dashboard: return NotchLayout.dashboardWidth
        case .assistant: return assistantWidth
        }
    }

    /// Size of the visible black shape for the current state.
    var shapeSize: CGSize {
        let band = geometry.topBandHeight
        switch mode {
        case .closed:
            let base = geometry.hasNotch ? geometry.notchWidth : 0
            if showsLiveActivity {
                let wing = env.timers.timers.isEmpty ? NotchLayout.liveActivityWing : NotchLayout.liveActivityWing + 18
                return CGSize(width: max(base, 150) + wing * 2, height: band)
            }
            // Without a notch the closed shape is a zero-height sliver at the top edge,
            // so opening still grows downward from the top center.
            return CGSize(width: geometry.hasNotch ? base : 180, height: geometry.hasNotch ? band : 0)
        case .dashboard:
            return CGSize(width: NotchLayout.dashboardWidth, height: band + NotchLayout.dashboardBodyHeight)
        case .assistant:
            let body = min(NotchLayout.maxAssistantBody, max(44, assistantBodyHeight))
            return CGSize(width: assistantWidth, height: band + body)
        }
    }

    var assistantWidth: CGFloat {
        cards.contains { if case .music = $0 { return true } else { return false } }
            ? NotchLayout.musicAssistantWidth : NotchLayout.assistantWidth
    }

    var topRadius: CGFloat {
        switch mode {
        case .closed: return showsLiveActivity ? 6 : 0
        case .dashboard, .assistant: return NotchLayout.openTopRadius
        }
    }

    var bottomRadius: CGFloat {
        switch mode {
        case .closed: return showsLiveActivity ? 12 : 10
        case .dashboard, .assistant: return NotchLayout.openBottomRadius
        }
    }

    var wantsKeyFocus: Bool { mode == .assistant && phase == .textInput }
    var isOpen: Bool { mode != .closed }

    // MARK: - Gesture entry points

    func activateVoice() {
        guard !settings.bool(.paused) else { return }
        beginAssistantSession()
        phase = .listening
        playActivationSound()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startCapture()
        case .notDetermined:
            Task {
                if await env.permissions.requestMicrophone() {
                    if phase == .listening { startCapture() }
                } else {
                    showError("IVY needs microphone access to listen.", action: .openPrivacy(.microphone))
                }
            }
        default:
            showError("IVY needs microphone access to listen.", action: .openPrivacy(.microphone))
        }
        prewarmModels()
    }

    func finishVoice() {
        guard mode == .assistant, phase == .listening else { return }
        let samples = capture.stop()
        audioLevel = 0
        guard samples.count > Int(AudioCaptureService.sampleRate * 0.35) else {
            showError("I didn't catch that.")
            return
        }
        guard env.whisper.isAvailable else {
            showError(missingModelMessage(ModelCatalog.defaultWhisper), action: .openSettings("voice"))
            return
        }
        phase = .transcribing
        let id = runID
        runTask = Task {
            do {
                let text = try await env.whisper.transcribe(samples: samples, sampleRate: AudioCaptureService.sampleRate)
                guard id == runID else { return }
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.isEmpty {
                    showError("I didn't catch that.")
                } else {
                    submit(cleaned)
                }
            } catch {
                guard id == runID else { return }
                showError(error.localizedDescription)
            }
        }
    }

    func enterTextMode() {
        guard !settings.bool(.paused) else { return }
        if capture.isRunning { capture.stop() }
        audioLevel = 0
        if mode != .assistant || phase == .listening {
            beginAssistantSession()
        }
        typedText = ""
        phase = .textInput
        cancelCollapse()
        onKeyFocusChange?(true)
        prewarmModels(speech: false)
    }

    func submitTypedText() {
        let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typedText = ""
        onKeyFocusChange?(false)
        submit(text)
    }

    // MARK: - Agent

    func submit(_ text: String) {
        runTask?.cancel()
        let id = UUID()
        runID = id
        mode = .assistant
        query = text
        answer = ""
        cards = []
        workingLabel = nil
        workingDone = false
        errorAction = nil
        phase = .thinking
        cancelCollapse()

        runTask = Task {
            var outcome: AgentOutcome?
            var failure: String?
            for await event in env.agent.run(text) {
                if id == runID {
                    handle(event)
                }
                if case .finished(let result) = event { outcome = result }
                if case .failed(let message) = event { failure = message }
            }
            // History is recorded even if the UI was dismissed meanwhile.
            await record(query: text, outcome: outcome, failure: failure)
            guard id == runID, mode == .assistant else { return }
            if let outcome { finish(with: outcome) }
        }
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .modelLoading:
            phase = .loadingModel
        case .thinking:
            if case .executing = phase { return }
            phase = .thinking
        case .partialText(let text):
            answer = text
            phase = .responding
        case .toolStarted(_, let displayName):
            workingLabel = displayName
            workingDone = false
            phase = .executing(displayName)
        case .awaitingConfirmation:
            break // presented by requestConfirmation(_:)
        case .toolFinished(_, let result):
            workingDone = true
            if let card = result.card { upsert(card) }
        case .finished(let outcome):
            answer = outcome.text
            cards = outcome.cards
        case .failed(let message):
            showError(message, action: message.contains("Settings") ? .openSettings("ai") : nil)
        }
    }

    private func finish(with outcome: AgentOutcome) {
        phase = .answered
        if settings.ttsEnabled, env.tts.isAvailable, !outcome.text.isEmpty {
            phase = .speaking
            let text = outcome.text
            let id = runID
            speakTask = Task {
                do {
                    try await env.tts.speak(text)
                } catch {
                    Log.tts.error("Speech failed: \(error.localizedDescription, privacy: .public)")
                }
                guard id == runID else { return }
                if phase == .speaking { phase = .answered }
                scheduleCollapse()
            }
        } else {
            scheduleCollapse()
        }
    }

    private func upsert(_ card: ResultCard) {
        if case .music = card, let index = cards.firstIndex(where: { if case .music = $0 { return true } else { return false } }) {
            cards[index] = card
        } else if !cards.contains(card) {
            cards.append(card)
        }
    }

    // MARK: - Confirmation

    /// Called by the agent for high-risk actions; suspends until the user decides.
    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        confirmationContinuation?.resume(returning: false)
        mode = .assistant
        confirmation = request
        phase = .confirming
        cancelCollapse()
        return await withCheckedContinuation { continuation in
            confirmationContinuation = continuation
        }
    }

    func resolveConfirmation(_ approved: Bool) {
        confirmation = nil
        if phase == .confirming { phase = approved ? .executing(workingLabel ?? "Working") : .thinking }
        confirmationContinuation?.resume(returning: approved)
        confirmationContinuation = nil
    }

    // MARK: - Dashboard (hover)

    func openDashboard(tab: DashboardTab? = nil) {
        guard mode == .closed else {
            if mode == .dashboard, let tab { self.tab = tab }
            return
        }
        if let tab { self.tab = tab }
        mode = .dashboard
        env.battery.setVisible(true)
        env.music.beginLiveUpdates()
        Task { await reloadHistory() }
    }

    func closeDashboard() {
        guard mode == .dashboard, !isDropTargeted else { return }
        env.battery.setVisible(false)
        env.music.endLiveUpdates()
        mode = .closed
    }

    // MARK: - Dismissal

    func dismiss() {
        cancelCollapse()
        if mode == .dashboard {
            closeDashboard()
            return
        }
        guard mode == .assistant else { return }
        if capture.isRunning { capture.stop() }
        audioLevel = 0
        resolveConfirmation(false)
        // Model generation is cancelled; a tool that's already running (e.g. launching
        // Claude Code) is allowed to finish in the background and lands in history.
        if phase.isBusy, !isExecuting { runTask?.cancel() }
        runID = UUID()
        speakTask?.cancel()
        Task { await env.tts.stop() }
        env.timers.stopRinging()
        onKeyFocusChange?(false)
        mode = .closed
        phase = .answered
        env.shortcuts?.reset()
    }

    private var isExecuting: Bool {
        if case .executing = phase { return true }
        return false
    }

    func stopButtonTapped() {
        if env.timers.ringing != nil {
            env.timers.stopRinging()
            dismiss()
            return
        }
        if phase == .speaking {
            speakTask?.cancel()
            Task { await env.tts.stop() }
            phase = .answered
            scheduleCollapse()
        } else {
            dismiss()
        }
    }

    func clickedOutside() {
        switch mode {
        case .closed: return
        case .dashboard: closeDashboard()
        case .assistant:
            guard settings.bool(.dismissOnClickOutside), phase != .confirming, phase != .listening else { return }
            if phase == .textInput, !typedText.isEmpty { return }
            dismiss()
        }
    }

    func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        if !hovering, mode == .assistant, phase == .answered { scheduleCollapse() }
    }

    // MARK: - Collapse

    func scheduleCollapse(after override: TimeInterval? = nil) {
        cancelCollapse()
        let delay = override ?? settings.double(.autoCollapseSeconds)
        guard delay > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.mode == .assistant else { return }
                if self.isHovering || self.phase == .confirming || self.phase == .textInput
                    || self.phase == .speaking || self.phase.isBusy {
                    self.scheduleCollapse()
                    return
                }
                self.dismiss()
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }

    // MARK: - Coding sessions

    /// A background Claude Code session finished: pop the result up on the notch.
    func showSessionResult(_ info: CodingSessionInfo) {
        guard mode != .assistant || !phase.isBusy else { return }
        if mode == .dashboard { closeDashboard() }
        runID = UUID()
        mode = .assistant
        query = ""
        answer = info.status == .finished ? "\(info.projectName) is ready." : "\(info.agent) stopped working on \(info.projectName)."
        cards = [.codingSession(info)]
        workingLabel = nil
        phase = .answered
        NSSound(named: "Glass")?.play()
        scheduleCollapse(after: max(12, settings.double(.autoCollapseSeconds)))
    }

    // MARK: - Timers

    /// A timer or alarm went off: pop up on the notch with a Stop button.
    func showTimerFinished(_ timer: TimerInfo) {
        if mode == .dashboard { closeDashboard() }
        if mode == .assistant, phase.isBusy || phase == .listening || phase == .textInput { return }
        runID = UUID()
        mode = .assistant
        query = ""
        answer = timer.label.map { "\($0.capitalizedFirst) timer is done." } ?? (timer.isAlarm ? "It's \(Date().formatted(date: .omitted, time: .shortened))." : "Time's up!")
        cards = []
        workingLabel = nil
        phase = .answered
        scheduleCollapse(after: 30)
    }

    // MARK: - History

    func reloadHistory() async {
        history = await env.history.all()
    }

    func clearHistory() {
        Task {
            await env.history.clear()
            await reloadHistory()
        }
    }

    private func record(query: String, outcome: AgentOutcome?, failure: String?) async {
        guard settings.bool(.saveHistory) else { return }
        let tool = outcome?.toolNames.first
        var title = HistoryStore.title(forTool: tool, query: query)
        if case .codingSession(let info)? = outcome?.cards.first { title = "\(info.projectName): \(info.task)" }
        let entry = HistoryEntry(query: query, title: title, toolName: tool,
                                 result: outcome?.text ?? failure ?? "Cancelled",
                                 status: outcome?.status ?? (failure == nil ? .cancelled : .failure))
        await env.history.append(entry)
        await reloadHistory()
    }

    // MARK: - Helpers

    private func beginAssistantSession() {
        runTask?.cancel()
        runID = UUID()
        speakTask?.cancel()
        Task { await env.tts.stop() }
        resolveConfirmation(false)
        if mode == .dashboard {
            env.battery.setVisible(false)
            env.music.endLiveUpdates()
        }
        mode = .assistant
        query = ""
        answer = ""
        cards = []
        workingLabel = nil
        workingDone = false
        errorAction = nil
        cancelCollapse()
    }

    private func startCapture() {
        do {
            try capture.start()
        } catch {
            showError(error.localizedDescription, action: .openPrivacy(.microphone))
        }
    }

    private func prewarmModels(speech: Bool = true) {
        let env = self.env
        if speech, env.whisper.isAvailable { Task.detached { try? await env.whisper.prepare() } }
        if env.llm.isAvailable { Task.detached { try? await env.llm.loadModel() } }
    }

    private func playActivationSound() {
        guard settings.bool(.playActivationSound) else { return }
        let sound = NSSound(named: "Tink")
        sound?.volume = 0.35
        sound?.play()
    }

    private func missingModelMessage(_ model: ModelDescriptor) -> String {
        RuntimeManager.isRuntimeInstalled
            ? "\(model.displayName) isn't installed. Open IVY Settings to download it."
            : LocalModelError.runtimeNotInstalled.errorDescription ?? ""
    }

    private func showError(_ message: String, action: ErrorAction? = nil) {
        if capture.isRunning { capture.stop() }
        mode = .assistant
        phase = .error(message)
        errorAction = action
        scheduleCollapse(after: action == nil ? 3 : 8)
    }

    func performErrorAction() {
        guard let errorAction else { return }
        switch errorAction {
        case .openSettings(let section): env.openSettings(section: section)
        case .openPrivacy(let pane): env.permissions.open(pane)
        }
        dismiss()
    }
}
