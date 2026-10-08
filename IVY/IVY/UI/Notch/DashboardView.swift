import AppKit
import IVYCore
import SwiftUI

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
        // Files dropped anywhere on the dashboard are handled by `NotchDropTarget` (AppKit).
    }
}

struct DashboardHeader: View {
    @ObservedObject var model: NotchViewModel
    @AppStorage(SettingsKey.dashboardBatteryHeader.rawValue) private var showBattery = true
    @ObservedObject var battery: BatteryMonitor
    @Namespace private var tabs

    var body: some View {
        HStack(spacing: 4) {
            // Segmented tabs with a selection pill that slides between them.
            HStack(spacing: 2) {
                ForEach(DashboardTab.allCases) { tab in
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { model.tab = tab }
                    } label: {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(model.tab == tab ? Color.white : Color.white.opacity(0.5))
                            .frame(width: 36, height: 22)
                            .background {
                                if model.tab == tab {
                                    Capsule().fill(Color.white.opacity(0.18))
                                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                                        .matchedGeometryEffect(id: "selection", in: tabs)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(tab.label)
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            Spacer()
            if showBattery, let reading = battery.reading {
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
    @AppStorage(SettingsKey.dashboardMusic.rawValue) private var showMusic = true
    @ObservedObject var model: NotchViewModel
    @ObservedObject var music: MusicController

    var body: some View {
        HStack(spacing: 18) {
            if showMusic {
                NowPlayingView(music: music)
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            }
            QuickActions(model: model, glance: model.env.glance)
                .frame(maxWidth: showMusic ? 190 : .infinity)
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
                    PlaybackProgress(state: state, tint: accent) { music.seek(to: $0) }
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

/// Right column of Home: today at a glance (reminders, next event, mail, Focus, battery)
/// with each line asking IVY for details, plus "Ask IVY".
struct QuickActions: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var glance: GlanceService

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(glance.items) { item in
                GlanceRow(item: item) { if let query = item.query { model.submit(query) } }
            }
            Spacer(minLength: 4)
            Button { model.enterTextMode() } label: {
                HStack(spacing: 6) {
                    Label("Ask IVY", systemImage: "text.cursor")
                    Spacer()
                    KeyCap(text: model.env.settings.activationShortcut.symbols)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(DashboardTileStyle())
        }
    }
}

struct GlanceRow: View {
    let item: GlanceService.Item
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(item.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var color: Color {
        switch item.tint {
        case .neutral: return .white.opacity(0.7)
        case .orange: return .orange
        case .red: return Color(red: 1, green: 0.42, blue: 0.4)
        case .green: return .green
        case .purple: return Color(red: 0.7, green: 0.6, blue: 1)
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
    /// Tiles that fit beside the AirDrop zone; older files collapse into a "+N" tile.
    private let visibleCount = 4

    var body: some View {
        HStack(spacing: 14) {
            // AirDrop target: drop files here to send them with AirDrop.
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.white.opacity(model.isAirDropTargeted ? 0.2 : 0.1)).frame(width: 52, height: 52)
                    Image(systemName: "square.and.arrow.up").font(.system(size: 17)).foregroundStyle(.white.opacity(0.8))
                }
                Text("AirDrop").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            }
            .frame(width: 150)
            .frame(maxHeight: .infinity)
            .background(DashedPanel(highlighted: model.isAirDropTargeted))
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { model.airDropZone = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in model.airDropZone = frame }
                    .onDisappear { model.airDropZone = nil }
            })
            .onTapGesture { ShelfStore.airDrop(shelf.items) }
            .help("Drop files to AirDrop them, or click to AirDrop everything on the shelf")

            Group {
                if shelf.items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(model.isDropTargeted ? 0.9 : 0.5))
                            .symbolEffect(.bounce, value: model.isDropTargeted)
                        Text("Drop files here").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        Text("They stay here until you drag them out").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let items = Array(shelf.items.reversed())
                    HStack(spacing: 6) {
                        ForEach(items.prefix(visibleCount), id: \.self) { url in
                            ShelfItemView(url: url, all: items,
                                          ask: { model.env.openSettings(section: "assistant"); model.env.workspaceAttachments = [url] },
                                          remove: { withAnimation(.spring(response: 0.3)) { shelf.remove(url) } })
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                        if items.count > visibleCount {
                            Button { ShelfQuickLook.shared.show(items, selecting: items[visibleCount]) } label: {
                                Text("+\(items.count - visibleCount)")
                                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.8))
                                    .frame(width: 44, height: 44)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                            .help("Preview all \(items.count) files")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxHeight: .infinity)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: shelf.items)
                    .overlay(alignment: .topTrailing) {
                        Button("Clear") { withAnimation(.easeOut(duration: 0.2)) { shelf.clear() } }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(8)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DashedPanel(highlighted: model.isDropTargeted, dashed: shelf.items.isEmpty || model.isDropTargeted))
        }
    }
}

/// One shelf file: Quick Look thumbnail, name and size. Click to preview, double-click to
/// open, drag out into any app.
struct ShelfItemView: View {
    let url: URL
    var all: [URL] = []
    var ask: () -> Void = {}
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            FileThumbnail(url: url, size: 50)
                .scaleEffect(hovering ? 1.06 : 1)
            VStack(spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1).truncationMode(.middle)
                Text(FileDetails.summary(url))
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            .frame(width: 70)
        }
        .padding(.vertical, 6).padding(.horizontal, 3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovering ? 0.08 : 0)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(.black.opacity(0.75)).overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5)))
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: -2)
                .help("Remove from Shelf")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onTapGesture { ShelfQuickLook.shared.show(all.isEmpty ? [url] : all, selecting: url) }
        // Drag files back out of the shelf into any app.
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Quick Look") { ShelfQuickLook.shared.show(all.isEmpty ? [url] : all, selecting: url) }
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Ask IVY about this file", action: ask)
            Divider()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
            Button("AirDrop") { ShelfStore.airDrop([url]) }
            Divider()
            Button("Remove from Shelf", action: remove)
        }
        .help("\(url.lastPathComponent)\nClick to preview, double-click to open")
    }
}

struct DashedPanel: View {
    var highlighted: Bool
    /// Dashed while it invites a drop; a quiet filled panel once it holds files.
    var dashed = true
    var body: some View {
        if dashed {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(highlighted ? 0.55 : 0.2), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(highlighted ? 0.06 : 0)))
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.04)))
        }
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
            // Plain stack (no AppKit ScrollView) so the notch mask clips it while animating.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.history.prefix(4)) { entry in
                    HistoryRow(entry: entry).onTapGesture { model.env.openSettings(section: "history") }
                }
                Spacer(minLength: 0)
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
        case ToolName.closeApp?: return "xmark.app"
        case ToolName.openURL?: return "globe"
        case ToolName.openFile?, ToolName.revealInFinder?: return "folder"
        case ToolName.openSettings?: return "gearshape"
        case ToolName.fileSearch?: return "doc.text.magnifyingglass"
        case ToolName.clipboard?: return "doc.on.clipboard"
        case ToolName.dictionary?: return "character.book.closed"
        case ToolName.mailSearch?: return "envelope"
        case ToolName.calendarCreate?, ToolName.calendarEvents?: return "calendar"
        case ToolName.shortcutRun?: return "square.stack.3d.up"
        case ToolName.focus?: return "moon"
        case ToolName.energyStatus?, ToolName.systemInfo?, ToolName.lowPowerMode?: return "battery.75percent"
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
