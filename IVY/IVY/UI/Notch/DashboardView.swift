import AppKit
import IVYCore
import SwiftUI
import UniformTypeIdentifiers

/// Hover dashboard (inspired by boring.notch): tabs + status in the menu-bar band,
/// a media player on Home, a drag-and-drop file shelf with AirDrop, and IVY's history.
struct DashboardView: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        VStack(spacing: 0) {
            DashboardHeader(model: model, battery: model.env.battery)
                .frame(height: model.geometry.topBandHeight)
            Group {
                switch model.tab {
                case .home: DashboardHome(model: model, music: model.env.music)
                case .shelf: ShelfView(model: model, shelf: model.env.shelf)
                case .history: HistoryListView(model: model)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity)
        }
        // Dropping files anywhere on the dashboard adds them to the shelf.
        .onDrop(of: [.fileURL], isTargeted: $model.isDropTargeted) { providers in
            loadFileURLs(from: providers) { urls in
                model.env.shelf.add(urls)
                model.tab = .shelf
            }
            return true
        }
    }
}

struct DashboardHeader: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var battery: BatteryMonitor

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DashboardTab.allCases) { tab in
                Button { model.tab = tab } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.tab == tab ? Color.white : Color.white.opacity(0.5))
                        .frame(width: 38, height: 24)
                        .background(Capsule().fill(Color.white.opacity(model.tab == tab ? 0.14 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.label)
            }
            Spacer()
            if let reading = battery.reading {
                HStack(spacing: 5) {
                    Text("\(reading.percent)%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                    BatteryGlyph(reading: reading)
                }
                .padding(.trailing, 6)
            }
            Button { model.env.openSettings() } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("IVY Settings")
        }
        .padding(.horizontal, NotchLayout.openTopRadius + 10)
    }
}

struct BatteryGlyph: View {
    let reading: BatteryMonitor.Reading

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.5), lineWidth: 1).frame(width: 24, height: 12)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(fill)
                .frame(width: max(2, 20 * CGFloat(reading.percent) / 100), height: 8)
                .padding(.leading, 2)
            if reading.isCharging {
                Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24)
            }
        }
        .overlay(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.5)).frame(width: 1.5, height: 4).offset(x: 2)
        }
    }

    private var fill: Color {
        if reading.isCharging || reading.isPluggedIn { return .green }
        return reading.percent <= 20 ? .red : .white
    }
}

// MARK: - Home

struct DashboardHome: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var music: MusicController

    var body: some View {
        HStack(spacing: 18) {
            NowPlayingView(music: music)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            QuickActions(model: model)
                .frame(width: 150)
        }
    }
}

/// Horizontal media player: artwork left, title/artist, progress and controls.
struct NowPlayingView: View {
    @ObservedObject var music: MusicController

    var body: some View {
        let state = music.state
        let accent = Color(red: 0.45, green: 0.78, blue: 0.52)
        HStack(spacing: 16) {
            ArtworkView(url: state?.artworkURL, size: 96, cornerRadius: 14)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 6) {
                if let state, state.hasTrack {
                    Text(state.title).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    Text(state.artist).font(.system(size: 13, weight: .medium)).foregroundStyle(accent).lineLimit(1)
                    PlaybackProgress(state: state, tint: accent)
                        .padding(.top, 4)
                    MediaControls(state: state, music: music)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(music.spotify.isInstalled ? "Nothing playing" : "Spotify isn't installed")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    Text(music.spotify.isInstalled ? "Say “Play music” or press play" : "IVY controls the Spotify desktop app")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    if music.spotify.isInstalled {
                        MediaControls(state: MusicState(status: .paused), music: music)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 6)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct QuickActions: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.enterTextMode() } label: {
                Label("Ask IVY", systemImage: "text.cursor")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(DashboardTileStyle())
            Button { model.submit("What's on my to-do list today?") } label: {
                Label("Today", systemImage: "checklist")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(DashboardTileStyle())
            HStack(spacing: 4) {
                Text("Hold").foregroundStyle(.white.opacity(0.4))
                KeyCap(text: model.env.settings.activationShortcut.symbols)
                Text("to talk").foregroundStyle(.white.opacity(0.4))
            }
            .font(.system(size: 11))
        }
    }
}

struct DashboardTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08)))
    }
}

// MARK: - Shelf

struct ShelfView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var shelf: ShelfStore
    @State private var airDropTargeted = false

    var body: some View {
        HStack(spacing: 14) {
            // AirDrop target: drop files here to send them with AirDrop.
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.white.opacity(airDropTargeted ? 0.2 : 0.1)).frame(width: 52, height: 52)
                    Image(systemName: "square.and.arrow.up").font(.system(size: 17)).foregroundStyle(.white.opacity(0.8))
                }
                Text("AirDrop").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            }
            .frame(width: 150)
            .frame(maxHeight: .infinity)
            .background(DashedPanel(highlighted: airDropTargeted))
            .onDrop(of: [.fileURL], isTargeted: $airDropTargeted) { providers in
                loadFileURLs(from: providers) { ShelfStore.airDrop($0) }
                return true
            }
            .onTapGesture { ShelfStore.airDrop(shelf.items) }
            .help("Drop files to AirDrop them, or click to AirDrop everything on the shelf")

            Group {
                if shelf.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 20)).foregroundStyle(.white.opacity(0.6))
                        Text("Drop files here").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(shelf.items, id: \.self) { url in
                                ShelfItemView(url: url) { shelf.remove(url) }
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(maxHeight: .infinity)
                    }
                    .overlay(alignment: .topTrailing) {
                        Button("Clear") { shelf.clear() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(8)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DashedPanel(highlighted: model.isDropTargeted))
        }
    }
}

struct ShelfItemView: View {
    let url: URL
    let remove: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 44, height: 44)
            Text(url.lastPathComponent)
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 70)
        }
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        // Drag files back out of the shelf into any app.
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("AirDrop") { ShelfStore.airDrop([url]) }
            Divider()
            Button("Remove from Shelf", action: remove)
        }
        .help(url.path)
    }
}

struct DashedPanel: View {
    var highlighted: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.white.opacity(highlighted ? 0.55 : 0.2), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(highlighted ? 0.06 : 0)))
    }
}

// MARK: - History

struct HistoryListView: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        if model.history.isEmpty {
            Text("No history yet. Hold \(model.env.settings.activationShortcut.symbols) and ask IVY something.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.history) { entry in
                        HistoryRow(entry: entry)
                    }
                }
            }
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(for: entry.toolName))
                .font(.system(size: 12))
                .foregroundStyle(Self.color(for: entry.toolName))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Text(entry.result).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer()
            if entry.status == .failure {
                Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange)
            }
            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
        }
        .padding(.vertical, 5)
        .help(entry.query)
    }

    static func symbol(for tool: String?) -> String {
        switch tool {
        case let name? where name.hasPrefix("reminders"): return "checklist"
        case let name? where name.hasPrefix("music"): return "music.note"
        case ToolName.startCodingSession?: return "sparkle"
        case ToolName.openApp?: return "app.badge"
        case ToolName.openURL?: return "globe"
        case ToolName.openFile?, ToolName.revealInFinder?: return "folder"
        case ToolName.openSettings?: return "gearshape"
        case nil: return "bubble.left"
        default: return "bolt"
        }
    }

    static func color(for tool: String?) -> Color {
        switch tool {
        case let name? where name.hasPrefix("music"): return .green
        case let name? where name.hasPrefix("reminders"): return .orange
        case ToolName.startCodingSession?: return Color(red: 0.85, green: 0.47, blue: 0.34)
        default: return .white.opacity(0.6)
        }
    }
}

/// Extracts file URLs from drag-and-drop item providers.
func loadFileURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let collector = URLCollector()
    let group = DispatchGroup()
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { collector.append(url) }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let urls = collector.urls
        MainActor.assumeIsolated { completion(urls) }
    }
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func append(_ url: URL) { lock.withLock { storage.append(url) } }
    var urls: [URL] { lock.withLock { storage } }
}
