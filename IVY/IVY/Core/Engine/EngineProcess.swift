import os
import Foundation
import IVYCore

/// Manages one long-lived `ivy_engine.py` process (one per role: llm, stt, tts) and the
/// JSON Lines protocol spoken over its stdin/stdout.
///
/// The process is started lazily on first use and stopped after an idle timeout, which
/// frees all model memory (important on a MacBook Air). The user never starts a server.
actor EngineProcess {
    enum EngineError: LocalizedError {
        case runtimeMissing
        case scriptMissing
        case exited(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .runtimeMissing: return LocalModelError.runtimeNotInstalled.errorDescription
            case .scriptMissing: return "IVY's engine script is missing from the app bundle."
            case .exited(let detail): return "The local engine stopped unexpectedly. \(detail)"
            case .failed(let message): return message
            }
        }
    }

    private struct Pending {
        let onEvent: @Sendable (JSONValue) -> Void
        let continuation: CheckedContinuation<JSONValue, Error>
    }

    let role: String
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var pending: [String: Pending] = [:]
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var stderrTail: [String] = []
    private var readerTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var lastUse = Date()

    /// Stop the process after this much inactivity (nil = never).
    var idleTimeout: TimeInterval?
    /// Model currently loaded in the process, if any.
    private(set) var loadedModelPath: String?

    init(role: String) {
        self.role = role
    }

    var isRunning: Bool { process?.isRunning == true }

    func setIdleTimeout(_ timeout: TimeInterval?) {
        idleTimeout = timeout
        scheduleIdleCheck()
    }

    // MARK: - Lifecycle

    func ensureStarted() async throws {
        if isRunning { return }
        let python = AppPaths.pythonExecutable
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw EngineError.runtimeMissing }
        guard let script = EngineProcess.scriptURL else { throw EngineError.scriptMissing }

        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--role", role]
        process.environment = EngineProcess.environment
        process.qualityOfService = .userInitiated

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Stream stdout lines in order through an AsyncStream so token events never reorder.
        let (lines, lineContinuation) = AsyncStream<String>.makeStream()
        let splitter = LineSplitter()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                lineContinuation.finish()
                return
            }
            for line in splitter.feed(data) { lineContinuation.yield(line) }
        }
        let stderrSplitter = LineSplitter()
        let role = self.role
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            for line in stderrSplitter.feed(data) {
                Log.engine.debug("[\(role, privacy: .public)] \(line, privacy: .public)")
                Task { await self?.appendStderr(line) }
            }
        }
        process.terminationHandler = { [weak self] proc in
            Task { await self?.handleTermination(pid: proc.processIdentifier, status: proc.terminationStatus) }
        }

        try process.run()
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        Log.engine.info("Started \(self.role, privacy: .public) engine (pid \(process.processIdentifier))")

        readerTask = Task { [weak self] in
            for await line in lines { await self?.handleLine(line) }
        }

        // Wait for the "ready" handshake (python imports can take a moment on first run).
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyContinuation = continuation
        }
        touch()
    }

    func stop() {
        guard let process else { return }
        Log.engine.info("Stopping \(self.role, privacy: .public) engine")
        if process.isRunning {
            try? write(["op": "shutdown"])
            let pid = process.processIdentifier
            // Give it a moment to exit cleanly, then terminate.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                if kill(pid, 0) == 0 { kill(pid, SIGTERM) }
            }
        }
        cleanup(error: EngineError.failed("Engine stopped."))
    }

    // MARK: - Requests

    /// Sends a request and waits for its `done` event. Intermediate events (tokens,
    /// audio chunks) are delivered to `onEvent`. Cancelling the calling task sends a
    /// cancel message; the engine then finishes the request early.
    @discardableResult
    func request(_ op: String, _ payload: [String: JSONValue] = [:],
                 onEvent: @escaping @Sendable (JSONValue) -> Void = { _ in }) async throws -> JSONValue {
        try await ensureStarted()
        let id = UUID().uuidString
        var message = payload
        message["id"] = .string(id)
        message["op"] = .string(op)
        touch()
        defer { touch() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                pending[id] = Pending(onEvent: onEvent, continuation: continuation)
                do {
                    try write(.object(message))
                } catch {
                    pending.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func cancel(id: String) {
        guard pending[id] != nil else { return }
        try? write(["op": "cancel", "target": .string(id)])
    }

    func cancelAll() {
        for id in pending.keys { cancel(id: id) }
    }

    /// Loads a model once; repeated calls with the same path are free.
    func load(modelPath: String) async throws {
        if loadedModelPath == modelPath, isRunning { return }
        try await request("load", ["model_path": .string(modelPath)])
        loadedModelPath = modelPath
    }

    // MARK: - Private

    private func write(_ value: JSONValue) throws {
        guard let stdinHandle else { throw EngineError.failed("Engine is not running.") }
        let line = value.jsonString() + "\n"
        try stdinHandle.write(contentsOf: Data(line.utf8))
    }

    private func handleLine(_ line: String) {
        guard let message = JSONValue.parse(line), let event = message["event"]?.stringValue else {
            Log.engine.error("Unparseable engine output")
            return
        }
        if event == "ready" {
            readyContinuation?.resume()
            readyContinuation = nil
            return
        }
        guard let id = message["id"]?.stringValue, let entry = pending[id] else { return }
        switch event {
        case "done":
            pending.removeValue(forKey: id)
            entry.continuation.resume(returning: message)
        case "error":
            pending.removeValue(forKey: id)
            let text = message["message"]?.stringValue ?? "Unknown engine error"
            entry.continuation.resume(throwing: EngineError.failed(text))
        default:
            entry.onEvent(message)
        }
    }

    private func appendStderr(_ line: String) {
        stderrTail.append(line)
        if stderrTail.count > 40 { stderrTail.removeFirst(stderrTail.count - 40) }
    }

    private func handleTermination(pid: Int32, status: Int32) {
        // Ignore late notifications from a process that was already replaced.
        guard let process, process.processIdentifier == pid else { return }
        Log.engine.info("\(self.role, privacy: .public) engine exited with status \(status)")
        let detail = stderrTail.suffix(3).joined(separator: " ")
        cleanup(error: EngineError.exited(detail))
    }

    private func cleanup(error: Error) {
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
        for (_, entry) in pending { entry.continuation.resume(throwing: error) }
        pending.removeAll()
        try? stdinHandle?.close()
        stdinHandle = nil
        process = nil
        loadedModelPath = nil
        readerTask?.cancel()
        readerTask = nil
    }

    private func touch() {
        lastUse = Date()
        scheduleIdleCheck()
    }

    private func scheduleIdleCheck() {
        idleTask?.cancel()
        guard let timeout = idleTimeout, timeout > 0 else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() {
        guard let timeout = idleTimeout, pending.isEmpty, isRunning,
              Date().timeIntervalSince(lastUse) >= timeout - 1 else { return }
        Log.engine.info("Unloading \(self.role, privacy: .public) engine after inactivity")
        stop()
    }

    // MARK: - Static configuration

    static var scriptURL: URL? {
        Bundle.main.url(forResource: "ivy_engine", withExtension: "py")
    }

    /// Offline-by-default environment: models are read from local folders only.
    static var environment: [String: String] {
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "PYTHONUNBUFFERED": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "HF_HUB_DISABLE_PROGRESS_BARS": "1",
            "TOKENIZERS_PARALLELISM": "false",
            "TRANSFORMERS_VERBOSITY": "error",
            "PYTHONWARNINGS": "ignore",
        ]
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] { env["TMPDIR"] = tmp }
        return env
    }
}

/// Splits a byte stream into UTF-8 lines. Used from a single readability handler.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}
