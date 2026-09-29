import os
import Foundation
import IVYCore

/// `LocalLLMService` backed by MLX-LM running Qwen3-4B (4-bit) in IVY's local engine.
///
/// Tool calling uses Qwen3's native chat-template format; the engine keeps a prompt
/// prefix KV cache so the fixed system prompt + tool schemas are prefilled only once.
final class MLXLLMService: LocalLLMService, @unchecked Sendable {
    private let engine = EngineProcess(role: "llm")
    private let settings: SettingsStore
    private let governor: EnergyGovernor

    init(settings: SettingsStore, governor: EnergyGovernor) {
        self.settings = settings
        self.governor = governor
    }

    /// Re-applies the idle timeout (the energy policy can shorten it while the engine runs).
    func applyIdleTimeout() async {
        await engine.setIdleTimeout(governor.idleTimeout(userMinutes: settings.int(.unloadAfterMinutes)))
    }

    var descriptor: ModelDescriptor {
        ModelCatalog.descriptor(id: settings.string(.llmModelID)).flatMap { $0.kind == .llm ? $0 : nil }
            ?? ModelCatalog.defaultLLM
    }

    /// A custom model path (Settings → AI → Model path) overrides the catalog model.
    var modelDirectory: URL {
        let custom = settings.string(.llmModelPath)
        if !custom.isEmpty { return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath) }
        return descriptor.directory(in: settings.modelsFolder)
    }

    var isAvailable: Bool {
        RuntimeManager.isRuntimeInstalled && ModelFiles.isInstalled(at: modelDirectory, kind: .llm)
    }

    var isLoaded: Bool {
        get async { await engine.loadedModelPath == modelDirectory.path }
    }

    func loadModel() async throws {
        guard RuntimeManager.isRuntimeInstalled else { throw LocalModelError.runtimeNotInstalled }
        guard ModelFiles.isInstalled(at: modelDirectory, kind: .llm) else {
            throw LocalModelError.modelNotInstalled(descriptor.displayName)
        }
        await applyIdleTimeout()
        let started = Date()
        try await engine.load(modelPath: modelDirectory.path)
        Log.llm.info("Model ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
    }

    func generate(messages: [ChatMessage], tools: [JSONValue], options: GenerationOptions,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> String {
        try await loadModel()
        let done = try await engine.request("generate", [
            "messages": .array(messages.map(\.jsonValue)),
            "tools": .array(tools),
            "max_tokens": .number(Double(options.maxTokens)),
            "temperature": .number(options.temperature),
            "top_p": .number(options.topP),
            "context_length": .number(Double(options.contextLength)),
        ]) { event in
            if event["event"]?.stringValue == "token", let text = event["text"]?.stringValue {
                onToken(text)
            }
        }
        if done["finish_reason"]?.stringValue == "cancelled" { throw CancellationError() }
        let prompt = done["prompt_tokens"]?.doubleValue ?? 0
        let cached = done["cached_tokens"]?.doubleValue ?? 0
        let firstToken = done["first_token_seconds"]?.doubleValue ?? 0
        Log.llm.info("Generated (prompt \(Int(prompt)), cached \(Int(cached)), first token \(firstToken, format: .fixed(precision: 2)) s)")
        return done["text"]?.stringValue ?? ""
    }

    func cancelGeneration() async {
        await engine.cancelAll()
    }

    func unloadModel() async {
        await engine.stop()
    }
}

/// Helpers to decide whether a model folder is complete.
enum ModelFiles {
    static let completeMarker = ".ivy-complete"

    static func isInstalled(at directory: URL, kind: ModelKind) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent(completeMarker).path) { return true }
        guard fm.fileExists(atPath: directory.appendingPathComponent("config.json").path),
              let files = try? fm.contentsOfDirectory(atPath: directory.path) else { return false }
        switch kind {
        case .llm: return files.contains { $0.hasSuffix(".safetensors") } && files.contains("tokenizer.json")
        case .whisper: return files.contains { $0.hasPrefix("weights.") }
        case .kokoro:
            return files.contains { $0.hasSuffix(".safetensors") }
                && fm.fileExists(atPath: directory.appendingPathComponent("voices").path)
        }
    }

    static func size(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
