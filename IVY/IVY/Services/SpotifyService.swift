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
    private let runner = AppleScriptRunner.shared

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
        let descriptor = try await execute(script)
        return Self.parseState(descriptor)
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

    func setVolume(_ level: Int) async throws {
        guard isRunning else { throw ToolError.unavailable("Spotify isn't running.") }
        let clamped = max(0, min(100, level))
        try await execute("tell application id \"\(Self.bundleID)\" to set sound volume to \(clamped)")
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

/// Resolves "Billie Jean" to a Spotify track without a Spotify developer account:
/// iTunes Search (public, no key) finds the canonical song, then song.link (Odesli,
/// public, no key) maps it to its Spotify URI. Can be disabled in Settings, in which
/// case IVY opens Spotify's own search instead.
struct TrackResolver: Sendable {
    struct Track: Sendable {
        var uri: String
        var title: String
        var artist: String
    }

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.httpAdditionalHeaders = ["User-Agent": "IVY/1.0 (macOS assistant)"]
        return URLSession(configuration: configuration)
    }

    func resolve(_ query: String) async throws -> Track? {
        let country = Locale.current.region?.identifier ?? "US"
        var search = URLComponents(string: "https://itunes.apple.com/search")!
        search.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "3"),
            URLQueryItem(name: "country", value: country),
        ]
        let (searchData, _) = try await session.data(from: search.url!)
        guard let results = JSONValue.parse(String(decoding: searchData, as: UTF8.self))?["results"]?.arrayValue,
              let first = results.first,
              let trackURL = first["trackViewUrl"]?.stringValue else { return nil }
        let title = first["trackName"]?.stringValue ?? query
        let artist = first["artistName"]?.stringValue ?? ""

        var links = URLComponents(string: "https://api.song.link/v1-alpha.1/links")!
        links.queryItems = [URLQueryItem(name: "url", value: trackURL), URLQueryItem(name: "userCountry", value: country)]
        let (linkData, _) = try await session.data(from: links.url!)
        guard let spotify = JSONValue.parse(String(decoding: linkData, as: UTF8.self))?["linksByPlatform"]?["spotify"] else {
            return nil
        }
        let candidates = [spotify["nativeAppUriDesktop"]?.stringValue, spotify["url"]?.stringValue].compactMap { $0 }
        for candidate in candidates {
            if let range = candidate.range(of: #"track[:/]([A-Za-z0-9]{10,40})"#, options: .regularExpression) {
                let id = candidate[range].dropFirst("track:".count)
                return Track(uri: "spotify:track:\(id)", title: title, artist: artist)
            }
        }
        return nil
    }
}
