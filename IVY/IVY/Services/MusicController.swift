import AppKit
import Combine
import IVYCore

/// Observable now-playing state shared by the notch live activity, the hover dashboard
/// and the Spotify card. Spotify broadcasts playback changes as distributed
/// notifications, so IVY does not need to poll while idle.
@MainActor
final class MusicController: ObservableObject {
    @Published private(set) var state: MusicState?
    @Published private(set) var lastError: String?

    let spotify: SpotifyService
    private var observer: NSObjectProtocol?
    private var liveTimer: Timer?
    private var liveClients = 0
    private var refreshTask: Task<Void, Never>?

    init(spotify: SpotifyService) {
        self.spotify = spotify
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo ?? [:]
            MainActor.assumeIsolated { self?.apply(notificationInfo: info) }
        }
        refresh()
    }

    var isPlaying: Bool { state?.status == .playing && state?.hasTrack == true }

    /// Fetch the full state (including artwork URL) from Spotify, if it is running.
    func refresh() {
        guard spotify.isRunning else {
            if state?.status != .unavailable, state != nil { state?.status = .unavailable }
            return
        }
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                let newState = try await spotify.state()
                guard !Task.isCancelled else { return }
                state = newState
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func update(_ newState: MusicState) {
        state = newState
    }

    /// Poll once per second while a playback UI is visible (progress, shuffle state…).
    func beginLiveUpdates() {
        liveClients += 1
        guard liveTimer == nil else { return }
        refresh()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func endLiveUpdates() {
        liveClients = max(0, liveClients - 1)
        if liveClients == 0 {
            liveTimer?.invalidate()
            liveTimer = nil
        }
    }

    func perform(_ control: SpotifyService.Control) {
        // Optimistic UI for instant feedback.
        switch control {
        case .toggle: state?.status = state?.status == .playing ? .paused : .playing
        case .pause: state?.status = .paused
        case .play, .resume: state?.status = .playing
        case .shuffleOn: state?.shuffling = true
        case .shuffleOff: state?.shuffling = false
        case .repeatOn: state?.repeating = true
        case .repeatOff: state?.repeating = false
        default: break
        }
        if let current = state { state?.position = current.position(at: Date()); state?.capturedAt = Date() }
        Task {
            do {
                try await spotify.control(control)
                try? await Task.sleep(for: .milliseconds(350))
                refresh()
            } catch {
                lastError = error.localizedDescription
                refresh()
            }
        }
    }

    private func apply(notificationInfo info: [AnyHashable: Any]) {
        let playerState = (info["Player State"] as? String)?.lowercased() ?? ""
        let status: PlaybackStatus = playerState == "playing" ? .playing : playerState == "paused" ? .paused : .stopped
        let trackID = info["Track ID"] as? String
        let trackChanged = trackID != state?.trackID
        var next = state ?? MusicState(status: status)
        next.status = status
        if let name = info["Name"] as? String { next.title = name }
        if let artist = info["Artist"] as? String { next.artist = artist }
        if let album = info["Album"] as? String { next.album = album }
        if let duration = info["Duration"] as? Double { next.duration = duration / 1000 }
        if let position = info["Playback Position"] as? Double { next.position = position }
        next.trackID = trackID
        next.capturedAt = Date()
        if trackChanged { next.artworkURL = nil }
        state = next
        // Artwork isn't part of the notification; fetch it once per track change.
        if trackChanged || next.artworkURL == nil { refresh() }
    }
}
