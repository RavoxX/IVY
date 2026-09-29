import os
import Foundation
import IVYCore

/// Local speech-to-text with MLX Whisper (default: whisper-large-v3-turbo).
///
/// Audio flows microphone → memory → a private temp file → engine → deleted. Nothing is
/// uploaded and no recording is kept after transcription.
final class LocalWhisperService: SpeechRecognitionService, @unchecked Sendable {
    private let engine = EngineProcess(role: "stt")
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var descriptor: ModelDescriptor {
        ModelCatalog.descriptor(id: settings.string(.speechModelID)).flatMap { $0.kind == .whisper ? $0 : nil }
            ?? ModelCatalog.defaultWhisper
    }

    var modelDirectory: URL { descriptor.directory(in: settings.modelsFolder) }

    var isAvailable: Bool {
        RuntimeManager.isRuntimeInstalled && ModelFiles.isInstalled(at: modelDirectory, kind: .whisper)
    }

    func prepare() async throws {
        guard RuntimeManager.isRuntimeInstalled else { throw LocalModelError.runtimeNotInstalled }
        guard ModelFiles.isInstalled(at: modelDirectory, kind: .whisper) else {
            throw LocalModelError.modelNotInstalled(descriptor.displayName)
        }
        let minutes = settings.int(.unloadAfterMinutes)
        await engine.setIdleTimeout(minutes > 0 ? TimeInterval(minutes * 60) : nil)
        try await engine.load(modelPath: modelDirectory.path)
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        precondition(sampleRate == 16_000, "Whisper expects 16 kHz audio")
        try await prepare()

        let folder = AppPaths.temporary
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("\(UUID().uuidString).f32")
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        guard FileManager.default.createFile(atPath: file.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw LocalModelError.engineFailed("Couldn't prepare audio for transcription.")
        }
        // The recording is deleted as soon as transcription finishes (or fails).
        defer { try? FileManager.default.removeItem(at: file) }

        let language = settings.string(.speechLanguage)
        let done = try await engine.request("transcribe", [
            "pcm_path": .string(file.path),
            "language": .string(language.isEmpty ? "auto" : language),
        ])
        let seconds = done["seconds"]?.doubleValue ?? 0
        Log.speech.info("Transcribed \(samples.count / 16_000) s of audio in \(seconds, format: .fixed(precision: 2)) s")
        return done["text"]?.stringValue ?? ""
    }

    func unload() async {
        await engine.stop()
    }
}
