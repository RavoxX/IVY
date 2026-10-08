import AppKit
import Combine
import IVYCore
import OpenDirectory
import os

/// Face ID for the Mac: when the screen locks or wakes, IVY looks for an enrolled face and,
/// if it matches and passes the liveness check, types the stored login password.
///
/// Off by default. A 2D webcam is not a depth sensor, so this is a convenience feature, not a
/// security upgrade (see Settings ▸ Face ID). Templates and the password are kept in
/// `FaceIDVault`; camera frames stay in memory and are never saved.
@MainActor
final class FaceUnlockService: ObservableObject {
    enum ScanMode { case unlock, test }

    @Published private(set) var isVaultUnlocked = false
    @Published private(set) var templates: [FaceTemplate] = []
    @Published private(set) var hasPassword = false
    @Published private(set) var status = ""
    /// Shows a notice in the notch; used after unlocking when Face ID was on but couldn't run.
    var onSetupNeeded: ((String) -> Void)?
    /// Why Face ID skipped the current lock, reported once the user unlocks by password.
    private var skippedReason: String?
    @Published private(set) var isScanning = false
    @Published private(set) var isEnrolling = false

    let camera = FaceCamera()
    let overlay = FaceUnlockOverlay()
    let vault = FaceIDVault()
    private let settings: SettingsStore
    private let monitor = LockScreenMonitor()
    private var analyzer: FaceAnalyzer?
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var lastScanStart: TimeInterval = 0
    private var pendingTrigger: DispatchWorkItem?

    init(settings: SettingsStore) {
        self.settings = settings
        monitor.onEvent = { [weak self] event in self?.handle(event) }
        overlay.onHoverRetry = { [weak self] in
            guard let self, !self.isScanning, LockScreenMonitor.isScreenLocked else { return }
            self.startScan(.unlock)
        }
    }

    var isEnabled: Bool { settings.bool(.faceUnlockEnabled) }
    var hasData: Bool { vault.hasData }
    var isReady: Bool { isVaultUnlocked && hasPassword && templates.contains { $0.isEnabled } }

    /// Everything Face Unlock still needs, in the order Settings shows it.
    var missingRequirement: String? {
        if !FaceCamera.isAuthorized { return "Allow camera access." }
        if !PasswordTyper.isTrusted { return "Allow Accessibility so IVY can type your password on the lock screen." }
        if !isVaultUnlocked { return "Unlock Face ID with Touch ID once after IVY starts." }
        if !templates.contains(where: \.isEnabled) { return "Set up your face." }
        if !hasPassword { return "Save your Mac login password." }
        return nil
    }

    // MARK: - Launch

    /// Asks once after launch for Touch ID so the lock screen can use Face ID later; macOS
    /// can't show that prompt on the lock screen itself.
    func prepareAtLaunch() {
        guard isEnabled, vault.hasData else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await unlockVault()
        }
    }

    // MARK: - Vault

    @discardableResult
    func unlockVault() async -> Bool {
        do {
            try await vault.unlock(reason: "turn on Face ID for unlocking your Mac")
            try reloadContents()
            isVaultUnlocked = true
            status = ""
            return true
        } catch {
            isVaultUnlocked = vault.isUnlocked
            status = error.localizedDescription
            Log.faceID.error("Vault unlock failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func lockVault() {
        vault.lockVault()
        isVaultUnlocked = false
        templates = []
        hasPassword = false
    }

    private func reloadContents() throws {
        var contents = try vault.read()
        templates = contents.templates
        hasPassword = !contents.password.isEmpty
        contents.password.resetBytes(in: 0..<contents.password.count)
    }

    private func update(_ change: (inout FaceIDVault.Contents) -> Void) throws {
        var contents = try vault.read()
        defer { contents.password.resetBytes(in: 0..<contents.password.count) }
        change(&contents)
        try vault.write(contents)
        templates = contents.templates
        hasPassword = !contents.password.isEmpty
    }

    /// Checks the password against this Mac account before storing it, so a typo can never
    /// be typed into the lock screen over and over.
    func savePassword(_ password: String) async -> String? {
        guard isVaultUnlocked else { return FaceIDVaultError.locked.localizedDescription }
        let verified = await Task.detached(priority: .userInitiated) { Self.verifyLoginPassword(password) }.value
        guard verified else { return "That isn't the login password for \(NSUserName())." }
        do {
            try update { $0.password = Data(password.utf8) }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removePassword() {
        try? update { $0.password = Data() }
    }

    nonisolated private static func verifyLoginPassword(_ password: String) -> Bool {
        guard !password.isEmpty,
              let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        else { return false }
        return (try? record.verifyPassword(password)) != nil
    }

    func addTemplate(name: String, samples: [[Float]]) throws {
        let template = FaceTemplate(name: name, samples: samples, modelIdentifier: FaceAnalyzer.modelIdentifier)
        try update { $0.templates.append(template) }
        Log.faceID.info("Enrolled a face with \(samples.count) samples")
    }

    func setTemplate(_ id: UUID, enabled: Bool) {
        try? update { contents in
            if let index = contents.templates.firstIndex(where: { $0.id == id }) { contents.templates[index].isEnabled = enabled }
        }
    }

    func removeTemplate(_ id: UUID) {
        try? update { $0.templates.removeAll { $0.id == id } }
    }

    /// Deletes every face, the stored password and the keys, and turns Face ID off.
    func resetAll() {
        cancelScan()
        vault.reset()
        isVaultUnlocked = false
        templates = []
        hasPassword = false
        settings.set(false, for: .faceUnlockEnabled)
        status = ""
    }

    // MARK: - Models

    /// The Core ML model loads once (~7 MB) and stays for the app's lifetime.
    func loadAnalyzer() async throws -> FaceAnalyzer {
        if let analyzer { return analyzer }
        let loaded = try await Task.detached(priority: .userInitiated) { try FaceAnalyzer() }.value
        analyzer = loaded
        return loaded
    }

    func setEnrolling(_ enrolling: Bool) {
        if enrolling { cancelScan() }
        isEnrolling = enrolling
    }

    // MARK: - Lock screen triggers

    private func handle(_ event: LockScreenMonitor.Event) {
        switch event {
        case .unlocked:
            pendingTrigger?.cancel()
            overlay.detachFromLockScreen()
            if overlay.phase != .success { overlay.hide() }
            cancelScan()
            if let reason = skippedReason {
                skippedReason = nil
                onSetupNeeded?("Face ID didn't run on the lock screen. \(reason) (Settings ▸ Face ID)")
            }
        case .willSleep:
            pendingTrigger?.cancel()
            cancelScan()
            overlay.hide()
        case .locked:
            schedule(autoScan: settings.bool(.faceUnlockOnLock), after: 0.6)
        case .wake:
            schedule(autoScan: settings.bool(.faceUnlockOnWake), after: 0.4)
        }
    }

    /// Lock state lags right after wake, and one lid-open sends several wake signals; wait
    /// briefly and act once.
    private func schedule(autoScan: Bool, after delay: TimeInterval) {
        pendingTrigger?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.armIfPossible(autoScan: autoScan) }
        }
        pendingTrigger = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func armIfPossible(autoScan: Bool) {
        guard isEnabled, !isEnrolling, !monitor.isSleeping, LockScreenMonitor.isScreenLocked else { return }
        guard isReady, FaceCamera.isAuthorized, PasswordTyper.isTrusted else {
            let reason = missingRequirement ?? "Face ID isn't set up."
            skippedReason = reason
            status = "Face ID didn't run on the last lock. \(reason)"
            Log.faceID.notice("Face ID not armed: \(reason, privacy: .public)")
            return
        }
        skippedReason = nil
        guard !isScanning else { return }
        if autoScan, ProcessInfo.processInfo.systemUptime - lastScanStart > 2 {
            startScan(.unlock)
        } else {
            overlay.arm()
        }
    }

    // MARK: - Scanning

    func startScan(_ mode: ScanMode) {
        cancelScan()
        scanGeneration += 1
        let generation = scanGeneration
        lastScanStart = ProcessInfo.processInfo.systemUptime
        isScanning = true
        overlay.beginScan()
        scanTask = Task { [weak self] in
            await self?.runScan(mode, generation: generation)
        }
    }

    func cancelScan() {
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        if isScanning { camera.stop() }
        isScanning = false
    }

    private func runScan(_ mode: ScanMode, generation: Int) async {
        defer {
            if generation == scanGeneration {
                camera.stop()
                isScanning = false
            }
        }
        let analyzer: FaceAnalyzer
        do {
            analyzer = try await loadAnalyzer()
            try await camera.start()
        } catch {
            guard generation == scanGeneration else { return }
            status = error.localizedDescription
            overlay.finish(success: false, message: "Face ID Unavailable", thenArm: false)
            return
        }

        let templates = self.templates
        let threshold = settings.faceMatchStrictness.threshold
        let requireLiveness = settings.bool(.faceUnlockLiveness)
        let duration = max(3, min(15, settings.double(.faceUnlockScanSeconds)))
        // The scan window starts with the first camera frame, so camera warm-up (often
        // most of a second right after wake) doesn't eat into it.
        let warmUpDeadline = ProcessInfo.processInfo.systemUptime + 4
        while camera.latestFrame() == nil, ProcessInfo.processInfo.systemUptime < warmUpDeadline,
              generation == scanGeneration, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard generation == scanGeneration, !Task.isCancelled else { return }
        guard camera.latestFrame() != nil else {
            status = "The camera didn't deliver any frames."
            Log.faceID.error("No camera frames within 4 s")
            overlay.finish(success: false, message: "Camera Unavailable", thenArm: mode == .unlock && LockScreenMonitor.isScreenLocked)
            return
        }
        var judge = FaceScanJudge(startedAt: ProcessInfo.processInfo.systemUptime, duration: duration)
        var liveness = LivenessEvaluator()
        var lastFrame: UInt64 = 0
        var matchedName: String?

        while !judge.isFinished, generation == scanGeneration, !Task.isCancelled {
            if mode == .unlock, !LockScreenMonitor.isScreenLocked { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard let frame = camera.latestFrame(), frame.id != lastFrame else {
                if case .scanning(let hint) = judge.tick(at: now) { overlay.setHint(hint) }
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            lastFrame = frame.id
            let reading = await Task.detached(priority: .userInitiated) { analyzer.analyze(frame.image) }.value
            guard generation == scanGeneration else { return }
            let time = ProcessInfo.processInfo.systemUptime
            let verdict: FaceScanJudge.Verdict
            if let reading {
                let live = requireLiveness
                    ? liveness.observe(LivenessSample(time: time, eyeOpenness: reading.eyeOpenness, yaw: reading.yaw,
                                                      noseOffset: Double(reading.noseOffset.x))) != nil
                    : true
                let match = FaceMatcher.bestMatch(for: reading.embedding, in: templates,
                                                  modelIdentifier: FaceAnalyzer.modelIdentifier, threshold: threshold)
                matchedName = match?.name
                verdict = judge.observe(.face(matched: match != nil, live: live), at: time)
            } else {
                verdict = judge.observe(.noFace, at: time)
            }
            if case .scanning(let hint) = verdict { overlay.setHint(hint) }
        }
        guard generation == scanGeneration, !Task.isCancelled else { return }
        camera.stop()

        let stillLocked = mode == .unlock && LockScreenMonitor.isScreenLocked
        switch judge.verdict {
        case .recognized:
            if mode == .test {
                overlay.finish(success: true, message: matchedName.map { "Recognized \($0)" } ?? "Recognized", thenArm: false)
                status = "Face ID recognized \(matchedName ?? "you")."
            } else {
                await unlockMac()
            }
        case .notRecognized:
            overlay.finish(success: false, thenArm: stillLocked)
            status = "Face not recognized."
        case .timedOut:
            if stillLocked {
                overlay.arm()
            } else {
                overlay.finish(success: false, message: "No Face Found", thenArm: false)
            }
        case .scanning:
            break
        }
    }

    /// Recognized on the lock screen: show success, then type the stored password.
    private func unlockMac() async {
        guard LockScreenMonitor.isScreenLocked else { return }
        do {
            var contents = try vault.read()
            var password = contents.password
            contents.password.resetBytes(in: 0..<contents.password.count)
            defer { password.resetBytes(in: 0..<password.count) }
            guard !password.isEmpty else { throw FaceIDVaultError.locked }
            overlay.finish(success: true, thenArm: false)
            let typed = password
            try await Task.detached(priority: .userInitiated) { try PasswordTyper.type(typed) }.value
            Log.faceID.info("Face ID recognized the user; password typed")
        } catch {
            status = error.localizedDescription
            overlay.finish(success: false, message: "Face ID Unavailable", thenArm: true)
            Log.faceID.error("Face unlock failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Only claim success once macOS reports the session unlocked.
        try? await Task.sleep(for: .seconds(3))
        if LockScreenMonitor.isScreenLocked {
            status = "macOS didn't accept the stored password. Save your current login password again."
            Log.faceID.error("Screen still locked after typing the stored password")
        } else {
            status = "Unlocked with Face ID at \(Date().formatted(date: .omitted, time: .shortened))."
        }
    }
}
