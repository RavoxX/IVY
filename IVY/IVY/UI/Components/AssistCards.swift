import AppKit
import IVYCore
import SwiftUI

// MARK: - Files

/// Spotlight results: click to open, drag out, or send to the shelf.
struct FilesCard: View {
    let title: String
    let items: [FileHit]
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                Spacer()
                if items.count > 1 {
                    Button("Add All to Shelf") { shelf.add(items.prefix(6).map(\.url)) }
                        .buttonStyle(PillButtonStyle())
                }
            }
            ForEach(items.prefix(6)) { item in
                FileHitRow(item: item, onShelf: shelf.items.contains(item.url)) { shelf.add([item.url]) }
            }
            if items.count > 6 {
                Text("and \(items.count - 6) more").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

struct FileHitRow: View {
    let item: FileHit
    let onShelf: Bool
    let addToShelf: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 6)
            if hovering || onShelf {
                IconButton(symbol: onShelf ? "tray.full.fill" : "tray.and.arrow.down", size: 12, active: onShelf, action: addToShelf)
                    .help("Add to Shelf")
                IconButton(symbol: "magnifyingglass", size: 12) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    .help("Show in Finder")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { NSWorkspace.shared.open(item.url) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .help(item.url.path)
    }

    private var detail: String {
        let folder = (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        guard let modified = item.modified else { return folder }
        return "\(modified.formatted(.relative(presentation: .named))) · \(folder)"
    }
}

// MARK: - Text

/// Generated text (clipboard results) with a Copy button.
struct TextResultCard: View {
    let title: String
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    ClipboardService.write(text)
                    copied = true
                }
                .buttonStyle(PillButtonStyle(prominent: !copied))
            }
            Text(text)
                .font(.system(size: 12, design: looksStructured ? .monospaced : .default))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(16)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
    }

    private var looksStructured: Bool {
        let start = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)
        return start == "{" || start == "[" || start == "|" || text.contains("\",\"")
    }
}

// MARK: - Dictionary

struct DefinitionCard: View {
    let result: DefinitionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(result.word).font(.system(size: 17, weight: .bold, design: .serif)).foregroundStyle(.white)
                Spacer()
                Text(result.fromSystemDictionary ? "Dictionary" : "Local model")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
            if let definition = result.definition {
                Text(definition).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                    .lineLimit(6).fixedSize(horizontal: false, vertical: true)
            }
            wordList("Synonyms", result.synonyms)
            wordList("Opposites", result.antonyms)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
    }

    @ViewBuilder private func wordList(_ title: String, _ words: [String]) -> some View {
        if !words.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                Text(words.joined(separator: " · ")).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Mail

struct MailCard: View {
    let title: String
    let items: [MailMessageItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                AppIconView(bundleID: MailService.bundleID, size: 18)
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            }
            .padding(.bottom, 2)
            ForEach(items.prefix(6)) { item in
                Button {
                    if let url = MailService.url(forMessageID: item.id) { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(item.isRead ? Color.clear : Color.blue).frame(width: 7, height: 7).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(item.senderName).font(.system(size: 12, weight: item.isRead ? .medium : .bold))
                                    .foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                                Spacer()
                                Text(Self.dateLabel(item.date)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                            }
                            Text(item.subject.isEmpty ? "(No subject)" : item.subject)
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if items.count > 6 {
                Text("and \(items.count - 6) more").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    static func dateLabel(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Energy

struct EnergyCard: View {
    let snapshot: EnergySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                if let percent = snapshot.percent {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(percent)%").font(.system(size: 26, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                        Text(snapshot.isCharging ? "Charging" : snapshot.isPluggedIn ? "Plugged in" : "On battery")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    if let health = snapshot.healthPercent {
                        stat("Health", "\(health)% · \(EnergyAdvisor.healthLabel(health))")
                    }
                    if let cycles = snapshot.cycleCount { stat("Cycles", "\(cycles)") }
                    if let temperature = snapshot.temperatureCelsius { stat("Battery", "\(Int(temperature.rounded())) °C") }
                    stat("Thermal", snapshot.thermal.displayName, warn: snapshot.thermal == .serious || snapshot.thermal == .critical)
                    if let model = snapshot.modelName {
                        stat("AI model", snapshot.modelLoaded ? "\(model) loaded" : "Not loaded")
                    }
                }
            }
            let tips = EnergyAdvisor.advice(for: snapshot)
            if !tips.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(tips, id: \.self) { tip in
                        Label(tip, systemImage: "lightbulb").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
    }

    private func stat(_ title: String, _ value: String, warn: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.white.opacity(0.45))
            Text(value).foregroundStyle(warn ? Color.orange : .white.opacity(0.85))
        }
        .font(.system(size: 11).monospacedDigit())
    }
}
