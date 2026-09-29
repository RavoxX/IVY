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
            let resolver = TrackResolver(credentials: SpotifyCredentials.load(settings: context.settings))
            let resolution = await resolver.resolve(query)
            let expected = resolution.expected ?? TrackResolver.Metadata(title: query, artist: "", album: "")
            var spotifyResponded = false
            // Try candidates until Spotify really plays the requested song: some regional
            // IDs are unavailable and Spotify silently substitutes another track.
            for uri in resolution.uris.prefix(5) {
                try Task.checkCancellation()
                do {
                    try await spotify.play(uri: uri)
                } catch let error as ToolError {
                    throw error
                } catch {
                    continue
                }
                let (state, responded) = await waitForTrack(expected)
                spotifyResponded = spotifyResponded || responded
                if let state {
                    await MainActor.run { context.controller.update(state) }
                    return ToolResult(summary: "Playing \(MusicToolContext.describe(state)).", card: .music(state),
                                      historyTitle: "Spotify Music Playback")
                }
                // Spotify ignores playback commands entirely (signed out, or playing on another device).
                if !spotifyResponded { break }
                Log.spotify.info("Candidate didn't play the requested track; trying the next one")
            }
            if !resolution.uris.isEmpty {
                if !spotifyResponded {
                    return .failure("Spotify isn't responding to playback. Open Spotify and check that you're signed in and playing on this Mac.")
                }
                try? await spotify.control(.pause)
            }
        }
        // Honest fallback: show Spotify's search results rather than claiming playback.
        try await spotify.ensureRunning()
        try await spotify.openSearch(query)
        return ToolResult(summary: "I couldn't find “\(query)” to play directly, so I opened Spotify's search.",
                          historyTitle: "Spotify Search")
    }
}

extension MusicPlayTool {
    /// Polls Spotify for up to ~4.5 s until the requested song is playing.
    /// Returns the matching state, and whether Spotify showed any sign of playback.
    func waitForTrack(_ expected: TrackResolver.Metadata) async -> (MusicState?, Bool) {
        var responded = false
        for _ in 0..<11 {
            try? await Task.sleep(for: .milliseconds(400))
            guard let state = try? await context.spotify.state() else { continue }
            if state.hasTrack || state.status == .playing { responded = true }
            if state.hasTrack, TrackResolver.matches(playing: state.title, expected: expected.title),
               expected.artist.isEmpty || TrackResolver.artistMatches(playing: state.artist, expected: expected.artist) {
                return (state, true)
            }
        }
        return (nil, responded)
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
        guard context.spotify.isRunning else {
            // No music app to adjust: change the Mac's output volume instead.
            let direction = arguments.string("direction")?.lowercased() ?? "up"
            let level = arguments.int("level")
            return try await SystemVolumeTool().execute(
                arguments: level.map { ["action": "set", "level": .number(Double($0))] } ?? ["action": .string(direction)],
                context: toolContext)
        }
        let current = await context.spotify.currentVolume()
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
