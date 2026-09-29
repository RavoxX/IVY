import os
import Foundation
import IVYCore

/// Shared helpers for the music tools.
struct MusicToolContext: Sendable {
    let spotify: SpotifyService
    let controller: MusicController
    let settings: SettingsStore

    /// Reads the player state after a command settles and publishes it to the UI.
    func settledState(after delay: Duration = .milliseconds(600)) async -> MusicState? {
        try? await Task.sleep(for: delay)
        guard let state = try? await spotify.state() else { return nil }
        await MainActor.run { controller.update(state) }
        return state
    }

    static func describe(_ state: MusicState) -> String {
        state.artist.isEmpty ? state.title : "\(state.title) by \(state.artist)"
    }
}

struct MusicPlayTool: IVYTool {
    let context: MusicToolContext
    let name = ToolName.musicPlay
    let description = "Play music on Spotify. With a query, plays that song/artist; without one, resumes playback."
    let displayName = "Spotify"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [ToolParameter("query", .string, "Song and/or artist to play, e.g. 'Billie Jean' or 'Thriller by Michael Jackson'.")]
    }

    func execute(arguments: [String: JSONValue], context toolContext: ToolContext) async throws -> ToolResult {
        let spotify = context.spotify
        guard spotify.isInstalled else { return .failure("Spotify isn't installed.") }

        guard let query = arguments.string("query") else {
            try await spotify.control(.play)
            guard let state = await context.settledState(), state.hasTrack else {
                return ToolResult(summary: "Playing music.", historyTitle: "Spotify Music Playback")
            }
            return ToolResult(summary: "Playing \(MusicToolContext.describe(state)).", card: .music(state),
                              historyTitle: "Spotify Music Playback")
        }

        guard query.count <= 200 else { throw ToolError.invalidArgument("query", "too long") }
        if context.settings.bool(.onlineTrackLookup) {
            do {
                if let track = try await TrackResolver().resolve(query) {
                    try await spotify.play(uri: track.uri)
                    let state = await context.settledState(after: .milliseconds(900))
                    let playing = state.map(MusicToolContext.describe) ?? "\(track.title) by \(track.artist)"
                    return ToolResult(summary: "Playing \(playing).", card: state.map { .music($0) },
                                      historyTitle: "Spotify Music Playback")
                }
            } catch let error as ToolError {
                throw error
            } catch {
                Log.spotify.error("Track lookup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Honest fallback: show Spotify's search results rather than claiming playback.
        try await spotify.ensureRunning()
        try await spotify.openSearch(query)
        return ToolResult(summary: "I opened Spotify's search for “\(query)”.", historyTitle: "Spotify Search")
    }
}

struct MusicControlTool: IVYTool {
    let context: MusicToolContext
    let name = ToolName.musicControl
    let description = "Control Spotify playback: pause, resume, next, previous, toggle, shuffle or repeat."
    let displayName = "Spotify"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [ToolParameter("action", .string, "The playback action.", required: true,
                       enumValues: SpotifyService.Control.allCases.map(\.rawValue).filter { $0 != "play" })]
    }

    func execute(arguments: [String: JSONValue], context toolContext: ToolContext) async throws -> ToolResult {
        let raw = try arguments.requiredString("action").lowercased()
        guard let control = SpotifyService.Control(rawValue: raw) else {
            throw ToolError.invalidArgument("action", "unknown action \(raw)")
        }
        guard context.spotify.isInstalled else { return .failure("Spotify isn't installed.") }
        if control == .pause, !context.spotify.isRunning { return ToolResult(summary: "Nothing is playing.") }
        try await context.spotify.control(control)
        let state = await context.settledState()

        let summary: String
        switch control {
        case .pause: summary = "Paused."
        case .toggle: summary = state?.status == .playing ? "Playing." : "Paused."
        case .resume, .play: summary = state.map { "Playing \(MusicToolContext.describe($0))." } ?? "Resumed."
        case .next, .previous: summary = state.map { "Playing \(MusicToolContext.describe($0))." } ?? "Skipped."
        case .shuffleOn: summary = "Shuffle is on."
        case .shuffleOff: summary = "Shuffle is off."
        case .repeatOn: summary = "Repeat is on."
        case .repeatOff: summary = "Repeat is off."
        }
        let showCard = control != .pause && state?.hasTrack == true
        return ToolResult(summary: summary, card: showCard ? state.map { .music($0) } : nil,
                          historyTitle: "Spotify Music Playback")
    }
}

struct MusicNowPlayingTool: IVYTool {
    let context: MusicToolContext
    let name = ToolName.musicNowPlaying
    let description = "Get the song currently playing in Spotify."
    let displayName = "Spotify"
    let baseRisk = RiskLevel.low
    let parameters: [ToolParameter] = []

    func execute(arguments: [String: JSONValue], context toolContext: ToolContext) async throws -> ToolResult {
        guard context.spotify.isRunning else { return ToolResult(summary: "Spotify isn't playing anything.") }
        let state = try await context.spotify.state()
        await MainActor.run { context.controller.update(state) }
        guard state.hasTrack else { return ToolResult(summary: "Nothing is playing.") }
        let verb = state.status == .playing ? "is playing" : "is paused"
        return ToolResult(summary: "\(MusicToolContext.describe(state)) \(verb).", card: .music(state),
                          historyTitle: "Spotify Music Playback")
    }
}

struct MusicVolumeTool: IVYTool {
    let context: MusicToolContext
    let name = ToolName.musicVolume
    let description = "Change Spotify's volume: a direction (up/down) or an exact level 0-100."
    let displayName = "Spotify"
    let baseRisk = RiskLevel.low
    var parameters: [ToolParameter] {
        [
            ToolParameter("direction", .string, "up or down", enumValues: ["up", "down"]),
            ToolParameter("level", .integer, "Exact volume 0-100."),
        ]
    }

    func execute(arguments: [String: JSONValue], context toolContext: ToolContext) async throws -> ToolResult {
        guard context.spotify.isRunning else { return .failure("Spotify isn't running.") }
        let current = try await context.spotify.state().volume
        let target: Int
        if let level = arguments.int("level") {
            target = level
        } else {
            let direction = arguments.string("direction")?.lowercased() ?? "up"
            target = current + (direction == "down" ? -15 : 15)
        }
        let clamped = max(0, min(100, target))
        try await context.spotify.setVolume(clamped)
        return ToolResult(summary: "Volume \(clamped)%.", historyTitle: "Spotify Music Playback")
    }
}
