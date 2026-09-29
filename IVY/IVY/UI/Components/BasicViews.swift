import AppKit
import IVYCore
import QuartzCore
import SwiftUI

/// IVY's mark: a small ivy leaf that breathes while IVY is active.
struct IVYMark: View {
    var active: Bool
    @State private var pulse = false

    var body: some View {
        Image(systemName: "leaf.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(LinearGradient(colors: [Color(red: 0.55, green: 0.92, blue: 0.55),
                                                     Color(red: 0.16, green: 0.68, blue: 0.42)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
            .rotationEffect(.degrees(-20))
            .scaleEffect(active && pulse ? 1.12 : 1)
            .opacity(active && pulse ? 1 : 0.9)
            .animation(active ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
            .accessibilityLabel("IVY")
    }
}

struct QueryView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

struct ResponseView: View {
    let text: String
    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.88))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

struct LoadingView: View {
    let text: String?
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(.white)
            if let text {
                Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

struct ErrorView: View {
    let message: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(PillButtonStyle())
            }
        }
    }
}

/// "● Working" chip from the reference, turning into a checkmark when the tool is done.
struct WorkingChip: View {
    let label: String
    let done: Bool
    var failed = false

    var body: some View {
        HStack(spacing: 6) {
            if done && failed {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
            } else if done {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
            } else {
                ProgressView().controlSize(.mini).tint(.green)
            }
            Text(done ? label : "Working")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.1)))
    }
}

struct ListeningView: View {
    let level: Float
    let shortcut: ActivationShortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                WaveformView(level: level)
                    .frame(width: 64, height: 26)
                Text("Listening…")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Release to ask · release \(shortcut.primarySymbol) and press it again to type")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.vertical, 2)
    }
}

/// Live microphone waveform driven by the input level.
struct WaveformView: View {
    let level: Float
    private let weights: [CGFloat] = [0.35, 0.6, 0.9, 1.0, 0.75, 0.5, 0.8, 0.45, 0.3]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: max(4, 26 * weights[index] * CGFloat(max(0.12, level))))
            }
        }
        .animation(.easeOut(duration: 0.09), value: level)
    }
}

/// Footer input: a hint ("Type or hold ⌘ ⌥ to speak") that becomes a text field.
struct TextInputView: View {
    @ObservedObject var model: NotchViewModel
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if model.phase == .textInput {
                HStack(spacing: 8) {
                    Image(systemName: "text.cursor").foregroundStyle(.white.opacity(0.45))
                    TextField("Ask IVY anything…", text: $model.typedText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .focused($focused)
                        .onSubmit { model.submitTypedText() }
                    if !model.typedText.isEmpty {
                        Image(systemName: "return").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
                .onAppear { DispatchQueue.main.async { focused = true } }
            } else {
                Button { model.enterTextMode() } label: {
                    HStack(spacing: 5) {
                        Text("Type or hold")
                        KeyCap(text: model.env.settings.activationShortcut.symbols)
                        Text("to speak")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)))
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? .black : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(configuration.isPressed ? 0.2 : 0.12)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Small icon button used in media controls and the dashboard header.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 14
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? Color.green : Color.white.opacity(0.9))
                .frame(width: size + 16, height: size + 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Artwork & icons

struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius).fill(Color.white.opacity(0.08))
            AppIconView(bundleID: SpotifyService.bundleID, size: size * 0.7)
        }
    }
}

/// The real icon of an installed app (e.g. Spotify, Reminders) via NSWorkspace.
struct AppIconView: View {
    let bundleID: String
    let size: CGFloat

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.fill").resizable().frame(width: size * 0.8, height: size * 0.8)
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// Audio bars for the closed-notch live activity. Animated with Core Animation so the
/// render server does the work and IVY's process stays idle.
struct AudioBarsView: NSViewRepresentable {
    var isAnimating: Bool

    func makeNSView(context: Context) -> AudioBarsNSView { AudioBarsNSView() }

    func updateNSView(_ nsView: AudioBarsNSView, context: Context) {
        nsView.setAnimating(isAnimating)
    }
}

final class AudioBarsNSView: NSView {
    private var bars: [CALayer] = []
    private let durations: [CFTimeInterval] = [0.42, 0.31, 0.5, 0.36]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in durations {
            let bar = CALayer()
            bar.backgroundColor = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.5, alpha: 1).cgColor
            bar.cornerRadius = 1
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width: CGFloat = 2
        let spacing = (bounds.width - width * CGFloat(bars.count)) / CGFloat(max(1, bars.count - 1))
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(index) * (width + spacing) + width / 2, y: bounds.midY)
        }
    }

    func setAnimating(_ animating: Bool) {
        for (index, bar) in bars.enumerated() {
            if animating {
                guard bar.animation(forKey: "bounce") == nil else { continue }
                let animation = CABasicAnimation(keyPath: "transform.scale.y")
                animation.fromValue = 0.25
                animation.toValue = 1.0
                animation.duration = durations[index]
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(animation, forKey: "bounce")
            } else {
                bar.removeAnimation(forKey: "bounce")
                bar.transform = CATransform3DMakeScale(1, 0.3, 1)
            }
        }
    }
}
