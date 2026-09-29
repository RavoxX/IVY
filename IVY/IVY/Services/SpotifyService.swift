import os
import AppKit
import IVYCore

/// Runs fixed AppleScript templates on a dedicated serial queue (never the main thread).
/// Model output is never interpolated into scripts; the only dynamic values are
/// validated Spotify URIs and integers.
final class AppleScriptRunner: @unchecked Sendable {
    static let shared = AppleScriptRunner()
    private let queue = DispatchQueue(label: "com.ravoxx.IVY.applescript", qos: .userInitiated)

    struct ScriptError: LocalizedError {
        let code: Int
        let message: String
        var errorDescription: String? { message }
        /// errAEEventNotPermitted: the user denied Automation access.
        var isPermissionDenied: Bool { code == -1743 || code == -1744 }
    }

    func run(_ source: String) async throws -> NSAppleEventDescriptor {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var errorInfo: NSDictionary?
                let script = NSAppleScript(source: source)
                let result = script?.executeAndReturnError(&errorInfo)
                if let result {
                    continuation.resume(returning: result)
                } else {
                    let code = (errorInfo?[NSAppleScript.errorNumber] as? Int) ?? -1
                    let message = (errorInfo?[NSAppleScript.errorMessage] as? String) ?? "AppleScript failed"
                    continuation.resume(throwing: ScriptError(code: code, message: message))
                }
            }
        }
    }
}

/// Controls the installed Spotify desktop app locally via its AppleScript dictionary.
/// No Spotify Web API account or login is required.
final class SpotifyService: @unchecked Sendable {
    static let bundleID = "com.spotify.client"
    static let playbackNotification = Notification.Name("com.spotify.client.PlaybackStateChanged")
    private let runner = AppleScriptRunner.shared

    // Spotify 1.3's AppleScript *getters* can go stale (state "stopped", volume 0, no
    // current track) while commands keep working. Its PlaybackStateChanged distributed
    // notification stays accurate, so IVY keeps the latest one as a second source of truth.
    private let lock = NSLock()
    private var notified: MusicState?
    private var artworkCache: [String: URL] = [:]
    private var lastSetVolume: Int?
    /// Last known-good playback position: from Spotify's notifications or IVY's own seek.
    /// The AppleScript `player position` getter can lag behind a seek, which made the
    /// progress bar jump back.
    private var positionAnchor: (trackID: String, position: TimeInterval, at: Date, playing: Bool, fromSeek: Bool)?
    private var observer: NSObjectProtocol?

    /// Called (on any thread) whenever Spotify broadcasts a playback change.
    var onPlaybackChange: (@Sendable (MusicState) -> Void)?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.playbackNotification, object: nil, queue: nil
        ) { [weak self] notification in
            self?.handleNotification(notification.userInfo ?? [:])
        }
    }

    /// Latest state from Spotify's notifications, if any.
    var notifiedState: MusicState? { lock.withLock { notified } }

    static func parseNotification(_ info: [AnyHashable: Any]) -> MusicState? {
        guard let rawState = info["Player State"] as? String else { return nil }
        let status: PlaybackStatus
        switch rawState.lowercased() {
        case "playing": status = .playing
        case "paused": status = .paused
        default: status = .stopped
        }
        func number(_ key: String) -> Double? { (info[key] as? NSNumber)?.doubleValue ?? (info[key] as? Double) }
        return MusicState(status: status, title: info["Name"] as? String ?? "", artist: info["Artist"] as? String ?? "",
                          album: info["Album"] as? String ?? "", trackID: info["Track ID"] as? String,
                          duration: (number("Duration") ?? 0) / 1000, position: number("Playback Position") ?? 0,
                          capturedAt: Date())
    }

    private func handleNotification(_ info: [AnyHashable: Any]) {
        guard var state = Self.parseNotification(info) else { return }
        lock.withLock {
            if let id = state.trackID { state.artworkURL = artworkCache[id] }
            if let previous = notified, previous.trackID == state.trackID {
                state.shuffling = previous.shuffling
                state.repeating = previous.repeating
                state.volume = previous.volume
            }
            notified = state
            if let id = state.trackID {
                positionAnchor = (id, state.position, Date(), state.status == .playing, false)
            }
        }
        onPlaybackChange?(state)
        if state.artworkURL == nil, let id = state.trackID {
            Task { [weak self] in
                guard let self, let url = await Self.fetchArtwork(trackURI: id) else { return }
                let updated: MusicState? = self.lock.withLock {
                    self.artworkCache[id] = url
                    guard self.notified?.trackID == id else { return nil }
                    self.notified?.artworkURL = url
                    return self.notified
                }
                if let updated { self.onPlaybackChange?(updated) }
            }
        }
    }

    /// Album art via Spotify's public oEmbed endpoint (the AppleScript `artwork url` can be stale).
    static func fetchArtwork(trackURI: String) async -> URL? {
        guard let id = trackURI.split(separator: ":").last,
              let url = URL(string: "https://open.spotify.com/oembed?url=https://open.spotify.com/track/\(id)"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return JSONValue.parse(String(decoding: data, as: UTF8.self))?["thumbnail_url"]?.stringValue.flatMap(URL.init(string:))
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) }
    var isInstalled: Bool { appURL != nil }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }

    enum Control: String, CaseIterable {
        case play, pause, resume, toggle, next, previous
        case shuffleOn = "shuffle_on", shuffleOff = "shuffle_off"
        case repeatOn = "repeat_on", repeatOff = "repeat_off"
    }

    // MARK: - Lifecycle

    /// Launches Spotify in the background if needed. Returns false if it isn't installed.
    func ensureRunning() async throws {
        guard let appURL else { throw ToolError.unavailable("Spotify isn't installed.") }
        if isRunning { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = false
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        // Wait until it accepts Apple Events.
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(250))
            if isRunning, (try? await playerStateString()) != nil { return }
        }
        throw ToolError.unavailable("Spotify didn't start in time.")
    }

    // MARK: - State

    func state() async throws -> MusicState {
        guard isInstalled else { return MusicState(status: .unavailable) }
        guard isRunning else { return MusicState(status: .unavailable) }
        let script = """
        tell application id "\(Self.bundleID)"
            set ps to (player state as text)
            if ps is "stopped" then return {ps}
            set t to current track
            return {ps, name of t, artist of t, album of t, artwork url of t, id of t, duration of t, player position, shuffling, repeating, sound volume}
        end tell
        """
        let scripted: MusicState?
        do {
            scripted = Self.parseState(try await execute(script))
        } catch let error as ToolError {
            throw error
        } catch {
            scripted = nil
        }
        let fromNotification = notifiedState
        // Prefer the scripted state when it's live; otherwise trust the notification.
        if var live = scripted, live.hasTrack, live.status != .stopped {
            lock.withLock {
                if let id = live.trackID, live.artworkURL == nil { live.artworkURL = artworkCache[id] }
                if live.volume == 0, let volume = lastSetVolume { live.volume = volume }
                if let anchor = positionAnchor, anchor.trackID == live.trackID {
                    let elapsed = anchor.playing ? Date().timeIntervalSince(anchor.at) : 0
                    let expected = min(live.duration, anchor.position + elapsed)
                    // Right after IVY seeks, the getter can still report the old spot; and a stale
                    // getter reports 0:00 mid-song. Otherwise the scripted position wins (the user
                    // may have scrubbed in Spotify itself).
                    let recentSeek = anchor.fromSeek && Date().timeIntervalSince(anchor.at) < 10
                    let staleZero = live.position < 0.5 && expected > 2
                    if (recentSeek || staleZero), abs(live.position - expected) > 2.5 {
                        live.position = expected
                        live.capturedAt = Date()
                    }
                    // Keep the anchor in step with play/pause seen through scripting.
                    if (live.status == .playing) != anchor.playing {
                        positionAnchor = (anchor.trackID, live.position, Date(), live.status == .playing, anchor.fromSeek)
                    }
                }
            }
            return live
        }
        if var notified = fromNotification, notified.hasTrack {
            notified.volume = lock.withLock { lastSetVolume } ?? notified.volume
            return notified
        }
        if let scripted { return scripted }
        throw ToolError.unavailable("Spotify didn't report its playback state.")
    }

    /// Current volume; Spotify 1.3 may report 0 while playing, so fall back to what IVY last set.
    func currentVolume() async -> Int {
        let scripted = Int((try? await execute("tell application id \"\(Self.bundleID)\" to return sound volume"))?.int32Value ?? 0)
        if scripted > 0 { return scripted }
        return lock.withLock { lastSetVolume } ?? 50
    }

    static func parseState(_ descriptor: NSAppleEventDescriptor) -> MusicState {
        func item(_ index: Int) -> NSAppleEventDescriptor? {
            index <= descriptor.numberOfItems ? descriptor.atIndex(index) : nil
        }
        let status: PlaybackStatus
        switch item(1)?.stringValue ?? "" {
        case "playing": status = .playing
        case "paused": status = .paused
        default: status = .stopped
        }
        guard descriptor.numberOfItems >= 11 else { return MusicState(status: status) }
        return MusicState(
            status: status,
            title: item(2)?.stringValue ?? "",
            artist: item(3)?.stringValue ?? "",
            album: item(4)?.stringValue ?? "",
            artworkURL: item(5)?.stringValue.flatMap(URL.init(string:)),
            trackID: item(6)?.stringValue,
            duration: (item(7)?.doubleValue ?? 0) / 1000,
            position: item(8)?.doubleValue ?? 0,
            shuffling: item(9)?.booleanValue ?? false,
            repeating: item(10)?.booleanValue ?? false,
            volume: Int(item(11)?.int32Value ?? 50))
    }

    private func playerStateString() async throws -> String {
        try await execute("tell application id \"\(Self.bundleID)\" to return (player state as text)").stringValue ?? ""
    }

    // MARK: - Commands

    func control(_ control: Control) async throws {
        let command: String
        switch control {
        case .play, .resume: command = "play"
        case .pause: command = "pause"
        case .toggle: command = "playpause"
        case .next: command = "next track"
        case .previous: command = "previous track"
        case .shuffleOn: command = "set shuffling to true"
        case .shuffleOff: command = "set shuffling to false"
        case .repeatOn: command = "set repeating to true"
        case .repeatOff: command = "set repeating to false"
        }
        if control == .play || control == .resume {
            try await ensureRunning()
        } else if !isRunning {
            throw ToolError.unavailable("Spotify isn't running.")
        }
        try await execute("tell application id \"\(Self.bundleID)\" to \(command)")
    }

    /// Plays a Spotify URI such as `spotify:track:4uLU6hMCjMI75M1A2tKUQC`.
    func play(uri: String) async throws {
        guard uri.range(of: #"^spotify:(track|album|playlist|artist):[A-Za-z0-9]{10,40}$"#, options: .regularExpression) != nil else {
            throw ToolError.invalidArgument("uri", "not a Spotify URI")
        }
        try await ensureRunning()
        try await execute("tell application id \"\(Self.bundleID)\" to play track \"\(uri)\"")
    }

    /// Jumps to `seconds` into the current track.
    func seek(to seconds: TimeInterval, trackID: String?, playing: Bool) async throws {
        guard isRunning else { throw ToolError.unavailable("Spotify isn't running.") }
        let target = max(0, seconds)
        try await execute("tell application id \"\(Self.bundleID)\" to set player position to \(String(format: "%.1f", target))")
        lock.withLock {
            if let trackID { positionAnchor = (trackID, target, Date(), playing, true) }
            if notified?.trackID == trackID {
                notified?.position = target
                notified?.capturedAt = Date()
            }
        }
    }

    func setVolume(_ level: Int) async throws {
        guard isRunning else { throw ToolError.unavailable("Spotify isn't running.") }
        let clamped = max(0, min(100, level))
        try await execute("tell application id \"\(Self.bundleID)\" to set sound volume to \(clamped)")
        lock.withLock { lastSetVolume = clamped }
    }

    /// Opens Spotify's search for a query (fallback when a track can't be resolved).
    func openSearch(_ query: String) async throws {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let url = URL(string: "spotify:search:\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    private func execute(_ source: String) async throws -> NSAppleEventDescriptor {
        do {
            return try await runner.run(source)
        } catch let error as AppleScriptRunner.ScriptError where error.isPermissionDenied {
            Log.spotify.error("Automation permission for Spotify denied")
            throw ToolError.permissionDenied("Automation (IVY → Spotify)")
        } catch {
            Log.spotify.error("Spotify script failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}

