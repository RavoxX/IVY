import os
import Combine
import Foundation
import IVYCore

/// Installs and inspects IVY's local AI runtime (a private Python venv with MLX packages)
/// and downloads models on explicit user request. Nothing is downloaded silently.
@MainActor
final class RuntimeManager: ObservableObject {
    enum RuntimeStatus: Equatable {
        case unknown
        case missing
        case installing(String)
        case ready
        case failed(String)
    }

    enum ModelState: Equatable {
        case notInstalled
        case downloading(progress: Double, bytes: Int64, total: Int64)
        case installed
        case failed(String)
    }

    @Published private(set) var runtimeStatus: RuntimeStatus = .unknown
    @Published private(set) var modelStates: [String: ModelState] = [:]
    @Published private(set) var installLog: [String] = []
    @Published private(set) var packageVersions: [String: String] = [:]

    private let settings: SettingsStore
    private var downloads: [String: Process] = [:]

    init(settings: SettingsStore) {
        self.settings = settings
        refreshModels()
    }

    nonisolated static var isRuntimeInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: AppPaths.pythonExecutable.path)
    }

    static var setupScriptURL: URL? {
        Bundle.main.url(forResource: "setup_runtime", withExtension: "sh")
    }

    var freeDiskBytes: Int64 {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: - Status

    func refresh() {
        refreshModels()
        guard Self.isRuntimeInstalled else {
            if case .installing = runtimeStatus { return }
            runtimeStatus = .missing
            return
        }
        Task { await runDoctor() }
    }

    func refreshModels() {
        for model in ModelCatalog.all {
            if case .downloading = modelStates[model.id] { continue }
            let installed = ModelFiles.isInstalled(at: model.directory(in: settings.modelsFolder), kind: model.kind)
            modelStates[model.id] = installed ? .installed : .notInstalled
        }
    }

    func state(for model: ModelDescriptor) -> ModelState {
        modelStates[model.id] ?? .notInstalled
    }

    func isInstalled(_ model: ModelDescriptor) -> Bool {
        state(for: model) == .installed
    }

    private func runDoctor() async {
        guard let script = EngineProcess.scriptURL else { return }
        let result = await ProcessRunner.run(executable: AppPaths.pythonExecutable,
                                             arguments: [script.path, "--role", "doctor"],
                                             environment: EngineProcess.environment, timeout: 60)
        let line = result.stdout.split(separator: "\n").last.map(String.init) ?? ""
        guard let report = JSONValue.parse(line)?["report"], let packages = report["packages"]?.objectValue else {
            runtimeStatus = .failed("The runtime is installed but couldn't be verified.")
            return
        }
        packageVersions = packages.compactMapValues(\.stringValue)
        let required = ["mlx", "mlx_lm", "mlx_whisper", "mlx_audio", "misaki"]
        let missing = required.filter { packages[$0]?.stringValue == nil }
        runtimeStatus = missing.isEmpty ? .ready : .failed("Missing packages: \(missing.joined(separator: ", "))")
    }

    // MARK: - Runtime installation

    func installRuntime() {
        if case .installing = runtimeStatus { return }
        guard let script = Self.setupScriptURL else {
            runtimeStatus = .failed("Setup script missing from the app bundle.")
            return
        }
        runtimeStatus = .installing("Preparing…")
        installLog = []
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["IVY_RUNTIME_DIR"] = AppPaths.runtime.path
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let splitter = LineSplitter()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let lines = splitter.feed(data)
            Task { @MainActor [weak self] in self?.consumeInstallOutput(lines) }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                if status == 0 {
                    self.installLog.append("Runtime installed.")
                    self.refresh()
                } else {
                    self.runtimeStatus = .failed("Runtime installation failed (exit \(status)). See the log for details.")
                }
            }
        }
        do {
            try process.run()
        } catch {
            runtimeStatus = .failed(error.localizedDescription)
        }
    }

    private func consumeInstallOutput(_ lines: [String]) {
        for line in lines {
            if line.hasPrefix("IVY_STEP: ") {
                runtimeStatus = .installing(String(line.dropFirst("IVY_STEP: ".count)))
            }
            installLog.append(line)
        }
        if installLog.count > 400 { installLog.removeFirst(installLog.count - 400) }
    }

    // MARK: - Model downloads

    /// Only the files IVY needs (Kokoro's repo also ships PyTorch weights and samples).
    private func allowPatterns(for model: ModelDescriptor) -> [String] {
        switch model.kind {
        case .kokoro: return ["config.json", "*.safetensors", "*.json"]
        case .llm, .whisper: return []
        }
    }

    func download(_ model: ModelDescriptor) {
        guard downloads[model.id] == nil else { return }
        guard Self.isRuntimeInstalled, let script = EngineProcess.scriptURL else {
            modelStates[model.id] = .failed("Install the runtime first.")
            return
        }
        let destination = model.directory(in: settings.modelsFolder)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var arguments = [script.path, "--role", "download", "--repo", model.repo, "--dest", destination.path]
        for pattern in allowPatterns(for: model) { arguments += ["--allow", pattern] }

        let process = Process()
        process.executableURL = AppPaths.pythonExecutable
        process.arguments = arguments
        var env = EngineProcess.environment
        env.removeValue(forKey: "HF_HUB_OFFLINE")
        env.removeValue(forKey: "TRANSFORMERS_OFFLINE")
        process.environment = env
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let splitter = LineSplitter()
        let id = model.id
        let expected = model.approximateBytes
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            for line in splitter.feed(data) {
                guard let message = JSONValue.parse(line) else { continue }
                Task { @MainActor [weak self] in self?.handleDownloadEvent(message, id: id, expected: expected, destination: destination) }
            }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloads.removeValue(forKey: id)
                if status != 0, case .downloading = self.modelStates[id] {
                    self.modelStates[id] = .failed("Download failed. Check your internet connection.")
                }
            }
        }
        modelStates[model.id] = .downloading(progress: 0, bytes: 0, total: expected)
        downloads[model.id] = process
        Log.engine.info("Downloading \(model.repo, privacy: .public)")
        do {
            try process.run()
        } catch {
            downloads.removeValue(forKey: model.id)
            modelStates[model.id] = .failed(error.localizedDescription)
        }
    }

    private func handleDownloadEvent(_ message: JSONValue, id: String, expected: Int64, destination: URL) {
        switch message["event"]?.stringValue {
        case "progress":
            let bytes = Int64(message["bytes"]?.doubleValue ?? 0)
            let total = Int64(message["total"]?.doubleValue ?? 0)
            let denominator = total > 0 ? total : expected
            modelStates[id] = .downloading(progress: min(1, Double(bytes) / Double(max(1, denominator))),
                                           bytes: bytes, total: denominator)
        case "done":
            FileManager.default.createFile(atPath: destination.appendingPathComponent(ModelFiles.completeMarker).path,
                                           contents: Data())
            modelStates[id] = .installed
        case "error":
            modelStates[id] = .failed(message["message"]?.stringValue ?? "Download failed.")
        default:
            break
        }
    }

    func cancelDownload(_ model: ModelDescriptor) {
        downloads[model.id]?.terminate()
        downloads.removeValue(forKey: model.id)
        modelStates[model.id] = .notInstalled
    }

    func delete(_ model: ModelDescriptor) {
        cancelDownload(model)
        try? FileManager.default.removeItem(at: model.directory(in: settings.modelsFolder))
        refreshModels()
    }
}

/// Runs a short-lived process with fixed arguments and collects its output.
enum ProcessRunner {
    struct Result: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func run(executable: URL, arguments: [String], environment: [String: String]? = nil,
                    currentDirectory: URL? = nil, timeout: TimeInterval = 30) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let environment { process.environment = environment }
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                let deadline = DispatchTime.now() + timeout
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if process.isRunning { process.terminate() }
                }
                // Drain stderr concurrently so a full pipe can't deadlock the child.
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                let errData = errBox.data
                process.waitUntilExit()
                continuation.resume(returning: Result(status: process.terminationStatus,
                                                      stdout: String(decoding: outData, as: UTF8.self),
                                                      stderr: String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
