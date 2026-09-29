import AppKit
import IVYCore
import SwiftUI

/// Renders a tool's structured result as a compact card (never a chat bubble).
struct ResultCardView: View {
    let card: ResultCard
    @ObservedObject var model: NotchViewModel

    var body: some View {
        switch card {
        case .reminders(let title, let items):
            ReminderCard(title: title, items: items, service: model.env.reminders)
        case .music(let state):
            SpotifyCard(fallback: state, music: model.env.music)
        case .appLaunched(let name, let path):
            AppLaunchedRow(name: name, path: path)
        case .link(let title, let url):
            LinkRow(title: title, url: url)
        case .file(let url):
            FileRow(url: url)
        case .codingSession(let info):
            CodingSessionCard(info: info, service: model.env.claudeCode)
        case .list(let title, let rows):
            ListCard(title: title, rows: rows)
        case .settings:
            EmptyView()
        case .sources(_, let items):
            SourcesCard(items: items)
        case .timers(let timers):
            TimersCard(timers: timers, service: model.env.timers)
        case .weather(let report):
            WeatherCard(report: report)
        case .events(let title, let items):
            EventsCard(title: title, items: items)
        case .files(let title, let items):
            FilesCard(title: title, items: items, shelf: model.env.shelf)
        case .text(let title, let body):
            TextResultCard(title: title, text: body)
        case .definition(let result):
            DefinitionCard(result: result)
        case .mail(let title, let items):
            MailCard(title: title, items: items)
        case .energy(let snapshot):
            EnergyCard(snapshot: snapshot)
        }
    }
}

// MARK: - Reminders

struct ReminderCard: View {
    let title: String
    let items: [ReminderItem]
    let service: ReminderService
    @State private var completed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items.prefix(8)) { item in
                    row(item)
                    if item.id != items.prefix(8).last?.id {
                        Divider().overlay(Color.white.opacity(0.08))
                    }
                }
            }
            if items.count > 8 {
                Text("and \(items.count - 8) more")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func row(_ item: ReminderItem) -> some View {
        let isDone = completed.contains(item.id) || item.isCompleted
        return HStack(spacing: 10) {
            AppIconView(bundleID: "com.apple.reminders", size: 20)
            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(isDone ? 0.4 : 0.92))
                .strikethrough(isDone)
                .lineLimit(2)
            Spacer(minLength: 6)
            if let due = item.dueDate {
                Text(dueLabel(due, hasTime: item.hasDueTime))
                    .font(.system(size: 11))
                    .foregroundStyle(ReminderTransforms.isOverdue(item, now: Date()) ? Color.red.opacity(0.85) : .white.opacity(0.45))
            }
            Button {
                guard !isDone else { return }
                completed.insert(item.id)
                Task { _ = try? await service.complete(id: item.id) }
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isDone ? Color.green : Color.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Mark as done")
        }
        .padding(.vertical, 7)
    }

    private func dueLabel(_ date: Date, hasTime: Bool) -> String {
        let calendar = Calendar.current
        if hasTime && calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return hasTime ? "Tomorrow \(date.formatted(date: .omitted, time: .shortened))" : "Tomorrow" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Spotify

/// The compact Spotify playback card: large artwork, title, artist, progress and controls.
struct SpotifyCard: View {
    let fallback: MusicState
    @ObservedObject var music: MusicController

    private var state: MusicState {
        if let live = music.state, live.hasTrack { return live }
        return fallback
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                AppIconView(bundleID: SpotifyService.bundleID, size: 18)
                Text("Spotify").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Text(state.status.displayName).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
            ArtworkView(url: state.artworkURL, size: 200, cornerRadius: 10)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                Text(state.artist)
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PlaybackProgress(state: state) { music.seek(to: $0) }
            MediaControls(state: state, music: music, large: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
        .onAppear { music.beginLiveUpdates() }
        .onDisappear { music.endLiveUpdates() }
    }
}

struct PlaybackProgress: View {
    let state: MusicState
    var tint: Color = .white
    /// Called with the target position when the user scrubs the bar.
    var onSeek: ((TimeInterval) -> Void)?
    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let live = state.duration > 0 ? min(1, state.position(at: context.date) / state.duration) : 0
            let fraction = dragFraction ?? live
            let position = dragFraction.map { $0 * state.duration } ?? state.position(at: context.date)
            let active = onSeek != nil && (hovering || dragFraction != nil)
            VStack(spacing: 4) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18)).frame(height: active ? 6 : 4)
                        Capsule().fill(tint).frame(width: proxy.size.width * fraction, height: active ? 6 : 4)
                        if active {
                            Circle().fill(tint).frame(width: 11, height: 11)
                                .offset(x: proxy.size.width * fraction - 5.5)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard onSeek != nil, state.duration > 0, proxy.size.width > 0 else { return }
                            dragFraction = min(1, max(0, value.location.x / proxy.size.width))
                        }
                        .onEnded { _ in
                            if let dragFraction, let onSeek { onSeek(dragFraction * state.duration) }
                            dragFraction = nil
                        })
                    .onHover { hovering = $0 }
                }
                .frame(height: 12)
                .animation(.easeOut(duration: 0.12), value: active)
                HStack {
                    Text(Self.format(position))
                    Spacer()
                    Text(Self.format(state.duration))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(tint == .white ? Color.white.opacity(0.5) : tint.opacity(0.8))
            }
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct MediaControls: View {
    let state: MusicState
    @ObservedObject var music: MusicController
    var large = false

    var body: some View {
        HStack(spacing: large ? 18 : 22) {
            if large {
                IconButton(symbol: "shuffle", size: 13, active: state.shuffling) {
                    music.perform(state.shuffling ? .shuffleOff : .shuffleOn)
                }
            }
            IconButton(symbol: "backward.fill", size: large ? 17 : 16) { music.perform(.previous) }
            Button { music.perform(.toggle) } label: {
                Image(systemName: state.status == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: large ? 18 : 22, weight: .bold))
                    .foregroundStyle(large ? Color.black : Color.white)
                    .frame(width: large ? 44 : 34, height: large ? 44 : 34)
                    .background(Circle().fill(large ? Color.white : Color.clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            IconButton(symbol: "forward.fill", size: large ? 17 : 16) { music.perform(.next) }
            if large {
                IconButton(symbol: "repeat", size: 13, active: state.repeating) {
                    music.perform(state.repeating ? .repeatOff : .repeatOn)
                }
            }
        }
    }
}

// MARK: - Small rows

struct AppLaunchedRow: View {
    let name: String
    let path: String?

    var body: some View {
        HStack(spacing: 10) {
            if let path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 26, height: 26)
            }
            Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.9))
        }
    }
}

struct LinkRow: View {
    let title: String
    let url: URL

    var body: some View {
        if url.scheme == "http" || url.scheme == "https" {
            Button { NSWorkspace.shared.open(url) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "globe").foregroundStyle(.white.opacity(0.6))
                    Text(url.absoluteString).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
        } else {
            // App links (shortcuts://…) read as an action, not a URL.
            Button(title) { NSWorkspace.shared.open(url) }
                .buttonStyle(PillButtonStyle(prominent: true))
        }
    }
}

struct FileRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 26, height: 26)
            Text(FileManager.default.displayName(atPath: url.path))
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(PillButtonStyle())
        }
    }
}

struct ListCard: View {
    let title: String
    let rows: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            ForEach(rows.indices, id: \.self) { index in
                Text(rows[index])
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
    }
}

// MARK: - Coding sessions

struct CodingSessionCard: View {
    let info: CodingSessionInfo
    @ObservedObject var service: ClaudeCodeService

    private var live: CodingSessionInfo {
        service.sessions.first { $0.id == info.id } ?? info
    }

    var body: some View {
        let session = live
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color(red: 0.85, green: 0.47, blue: 0.34))
                    Image(systemName: session.agent == "Codex" ? "chevron.left.forwardslash.chevron.right" : "sparkle")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(session.projectName)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(session.task).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer()
                statusBadge(session)
            }
            if let detail = session.detail, session.status != .running || session.mode == .terminal {
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Open Folder") { NSWorkspace.shared.open(session.directory) }
                    .buttonStyle(PillButtonStyle())
                if session.status != .running {
                    let index = session.directory.appendingPathComponent("index.html")
                    if FileManager.default.fileExists(atPath: index.path) {
                        Button("Open Site") { NSWorkspace.shared.open(index) }
                            .buttonStyle(PillButtonStyle(prominent: true))
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
    }

    @ViewBuilder private func statusBadge(_ session: CodingSessionInfo) -> some View {
        switch session.status {
        case .running:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(.white)
                Text(session.mode == .terminal ? "Terminal" : "Working").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
        case .finished:
            Label("Done", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(.red)
        }
    }
}

// MARK: - Confirmation

struct ConfirmationCard: View {
    let request: ConfirmationRequest
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                Text("\(request.risk.displayName)-risk action").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            Text(request.prompt).font(.system(size: 13)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Cancel") { decide(false) }.buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { decide(true) }.buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.5)))
    }
}

// MARK: - Web sources

struct SourcesCard: View {
    let items: [SourceLink]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            ForEach(items.prefix(3)) { item in
                Button { NSWorkspace.shared.open(item.url) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                            Text(item.url.host ?? "").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Timers

struct TimersCard: View {
    let timers: [TimerInfo]
    @ObservedObject var service: TimerService

    var body: some View {
        // Prefer live timers (they may have been cancelled or finished since).
        let live = timers.compactMap { timer in service.timers.first { $0.id == timer.id } }
        VStack(spacing: 8) {
            ForEach(live.isEmpty ? timers : live) { timer in
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = timer.remaining(at: context.date)
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.12), lineWidth: 4)
                            Circle()
                                .trim(from: 0, to: timer.duration > 0 ? CGFloat(remaining / timer.duration) : 0)
                                .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: timer.isAlarm ? "alarm.fill" : "timer")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                        }
                        .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(timer.isAlarm ? timer.endDate.formatted(date: .omitted, time: .shortened) : DurationParser.countdown(remaining))
                                .font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                            Text(timer.isAlarm ? "\(timer.title) · in \(DurationParser.countdown(remaining))" : timer.title)
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer()
                        if service.timers.contains(where: { $0.id == timer.id }) {
                            Button { service.cancel(id: timer.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                                    .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .help("Cancel")
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
    }
}

/// Shown while a finished timer is ringing.
struct RingingView: View {
    @ObservedObject var service: TimerService
    let stop: () -> Void

    var body: some View {
        if let timer = service.ringing {
            HStack(spacing: 12) {
                Image(systemName: timer.isAlarm ? "alarm.waves.left.and.right.fill" : "timer")
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(.orange)
                    .symbolEffect(.bounce, options: .repeating)
                Text(timer.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Button("Stop", action: stop).buttonStyle(PillButtonStyle(prominent: true))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.15)))
        }
    }
}

// MARK: - Weather

struct WeatherCard: View {
    let report: WeatherReport

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: report.symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 34))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(report.temperature.rounded()))\(report.unit)")
                    .font(.system(size: 26, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                Text("\(report.location) · \(report.day)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(report.condition).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                Text("H \(Int(report.high.rounded()))°  L \(Int(report.low.rounded()))°")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                if let rain = report.precipitationChance {
                    Label("\(rain)%", systemImage: "drop.fill").font(.system(size: 11)).foregroundStyle(.cyan.opacity(0.8))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
    }
}

// MARK: - Calendar

struct EventsCard: View {
    let title: String
    let items: [CalendarEventItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            ForEach(items.prefix(8)) { event in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.orange).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title).font(.system(size: 13)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                        Text(event.isAllDay ? "All day" : "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    if !Calendar.current.isDateInToday(event.start) {
                        Text(event.start.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        }
    }
}
