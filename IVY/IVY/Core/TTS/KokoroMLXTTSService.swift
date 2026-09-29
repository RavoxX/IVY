import AVFoundation
import IVYCore

/// Text-to-speech with Kokoro-82M running on MLX (via mlx-audio) in IVY's local engine.
///
/// The engine streams one WAV per sentence; playback starts as soon as the first
/// sentence is ready. Voice responses are OFF by default (Settings → Voice).
final class KokoroMLXTTSService: TTSService, @unchecked Sendable {
    private let engine = EngineProcess(role: "tts")
    private let settings: SettingsStore
    private let player = ChunkedAudioPlayer()
    private let governor: EnergyGovernor

    init(settings: SettingsStore, governor: EnergyGovernor) {
        self.settings = settings
        self.governor = governor
    }

    /// Re-applies the idle timeout (the energy policy can shorten it while the engine runs).
    func applyIdleTimeout() async {
        await engine.setIdleTimeout(governor.idleTimeout(userMinutes: settings.int(.unloadAfterMinutes)))
    }

    var modelDirectory: URL { ModelCatalog.kokoro.directory(in: settings.modelsFolder) }

    var isAvailable: Bool {
        RuntimeManager.isRuntimeInstalled && ModelFiles.isInstalled(at: modelDirectory, kind: .kokoro)
    }

    func prepare() async throws {
        guard RuntimeManager.isRuntimeInstalled else { throw LocalModelError.runtimeNotInstalled }
        guard ModelFiles.isInstalled(at: modelDirectory, kind: .kokoro) else {
            throw LocalModelError.modelNotInstalled(ModelCatalog.kokoro.displayName)
        }
        await applyIdleTimeout()
        try await engine.load(modelPath: modelDirectory.path)
    }

    func speak(_ text: String) async throws {
        let cleaned = Self.speakable(text)
        guard !cleaned.isEmpty else { return }
        try await prepare()
        player.volume = Float(settings.double(.ttsVolume))
        player.reset()

        let outDir = AppPaths.temporary.appendingPathComponent("tts", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let voice = settings.string(.kokoroVoice)
        let player = self.player
        try await engine.request("synthesize", [
            "text": .string(cleaned),
            "voice": .string(voice.isEmpty ? "af_heart" : voice),
            "speed": .number(max(0.5, min(2.0, settings.double(.speechRate)))),
            "out_dir": .string(outDir.path),
        ]) { event in
            // Events arrive in order on the engine actor; schedule immediately.
            if event["event"]?.stringValue == "chunk", let path = event["path"]?.stringValue {
                player.enqueue(URL(fileURLWithPath: path))
            }
        }
        try Task.checkCancellation()
        await player.waitUntilFinished()
    }

    func stop() async {
        await engine.cancelAll()
        player.stop()
    }

    func unload() async {
        player.stop()
        await engine.stop()
    }

    /// Strips markdown and symbols that sound bad when spoken.
    static func speakable(_ text: String) -> String {
        text.replacingOccurrences(of: #"[*_#`>\[\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"https?://\S+"#, with: "the link", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Plays WAV chunks back-to-back with AVAudioEngine. Scheduling is thread-safe, so chunks
/// can be enqueued directly from the engine's event stream. Files are deleted after playback.
final class ChunkedAudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let lock = NSLock()
    private var outstanding = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var connectedFormat: AVAudioFormat?
    private var files: [URL] = []

    var volume: Float = 0.9 {
        didSet { node.volume = volume }
    }

    init() {
        engine.attach(node)
    }

    func reset() {
        stop()
    }

    func enqueue(_ url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        lock.lock()
        outstanding += 1
        files.append(url)
        let needsConnect = connectedFormat != file.processingFormat
        lock.unlock()

        if needsConnect {
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            lock.withLock { connectedFormat = file.processingFormat }
        }
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
        node.volume = volume
        node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.finished(url)
        }
        if !node.isPlaying { node.play() }
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if outstanding == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func stop() {
        node.stop() // Invokes pending completion handlers.
        lock.lock()
        let pendingFiles = files
        files.removeAll()
        outstanding = 0
        let toResume = waiters
        waiters.removeAll()
        lock.unlock()
        pendingFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        toResume.forEach { $0.resume() }
        if engine.isRunning { engine.stop() }
    }

    private func finished(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        lock.lock()
        files.removeAll { $0 == url }
        outstanding = max(0, outstanding - 1)
        var toResume: [CheckedContinuation<Void, Never>] = []
        if outstanding == 0 {
            toResume = waiters
            waiters.removeAll()
        }
        lock.unlock()
        toResume.forEach { $0.resume() }
    }
}
