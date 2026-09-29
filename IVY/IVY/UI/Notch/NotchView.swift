import IVYCore
import SwiftUI

/// Root of the notch panel. The black shape is anchored to the top center of the window
/// and animates between the closed notch, the hover dashboard and the assistant.
struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)

    var body: some View {
        let size = model.shapeSize
        let shape = NotchShape(topCornerRadius: model.topRadius, bottomCornerRadius: model.bottomRadius)
        ZStack(alignment: .top) {
            if size != .zero {
                NotchBackground(isOpen: model.isOpen, band: model.geometry.topBandHeight)
                    .clipShape(shape)
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(model.isOpen ? 0.45 : 0), radius: 18, y: 8)

                content
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .clipShape(shape)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Self.spring, value: size)
        .animation(Self.spring, value: model.mode)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .closed:
            if model.showsLiveActivity {
                LiveActivityView(model: model, music: model.env.music)
                    .transition(.opacity)
            }
        case .dashboard:
            DashboardView(model: model)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        case .assistant:
            AssistantView(model: model)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
    }
}

/// Opaque black at the top (merges with the camera housing), dark translucent below.
struct NotchBackground: View {
    let isOpen: Bool
    let band: CGFloat

    var body: some View {
        ZStack {
            if isOpen { VisualEffectBlur(material: .hudWindow) }
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: isOpen ? 0.12 : 1),
                .init(color: .black.opacity(isOpen ? 0.9 : 1), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}

// MARK: - Closed live activity

/// Closed-notch live activity: album art on the left wing, audio bars on the right.
struct LiveActivityView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var music: MusicController

    var body: some View {
        let band = model.geometry.topBandHeight
        HStack(spacing: 0) {
            ArtworkView(url: music.state?.artworkURL, size: band - 10, cornerRadius: 5)
                .padding(.leading, NotchLayout.openTopRadius)
            Spacer(minLength: 0)
            AudioBarsView(isAnimating: music.state?.status == .playing)
                .frame(width: 18, height: band - 14)
                .padding(.trailing, NotchLayout.openTopRadius + 4)
        }
        .frame(height: band)
    }
}

// MARK: - Assistant

struct AssistantView: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        VStack(spacing: 0) {
            AssistantHeader(model: model)
                .frame(height: model.geometry.topBandHeight)

            ScrollView(.vertical, showsIndicators: false) {
                AssistantBody(model: model)
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 14)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: BodyHeightKey.self, value: proxy.size.height)
                    })
            }
            .scrollDisabled(model.assistantBodyHeight <= NotchLayout.maxAssistantBody)
        }
        .onPreferenceChange(BodyHeightKey.self) { height in
            if abs(model.assistantBodyHeight - height) > 0.5 { model.assistantBodyHeight = height }
        }
    }
}

private struct BodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Header that lives in the menu-bar band beside the notch: IVY mark left, stop right.
struct AssistantHeader: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        HStack {
            IVYMark(active: model.phase == .listening || model.phase.isBusy || model.phase == .speaking)
                .frame(width: 16, height: 16)
            Spacer()
            Button(action: model.stopButtonTapped) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(.white.opacity(0.85))
                    .frame(width: 9, height: 9)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.phase == .speaking ? "Stop speaking" : "Close IVY (Esc)")
        }
        .padding(.horizontal, NotchLayout.openTopRadius + 12)
    }
}

struct AssistantBody: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .listening:
                ListeningView(level: model.audioLevel, shortcut: model.env.settings.activationShortcut)
            default:
                if !model.query.isEmpty {
                    QueryView(text: model.query)
                }
                statusSection
                if !model.answer.isEmpty {
                    ResponseView(text: model.answer)
                }
                ForEach(Array(model.cards.enumerated()), id: \.offset) { _, card in
                    ResultCardView(card: card, model: model)
                }
                if let confirmation = model.confirmation {
                    ConfirmationCard(request: confirmation) { model.resolveConfirmation($0) }
                }
                if let label = model.workingLabel, model.cards.isEmpty || !model.workingDone {
                    WorkingChip(label: label, done: model.workingDone)
                }
            }
            if model.phase != .listening {
                TextInputView(model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: model.phase)
    }

    @ViewBuilder private var statusSection: some View {
        switch model.phase {
        case .transcribing:
            LoadingView(text: "Transcribing…")
        case .loadingModel:
            LoadingView(text: "Loading local model…")
        case .thinking:
            if model.answer.isEmpty { LoadingView(text: nil) }
        case .error(let message):
            ErrorView(message: message, actionTitle: actionTitle) { model.performErrorAction() }
        default:
            EmptyView()
        }
    }

    private var actionTitle: String? {
        switch model.errorAction {
        case .openSettings?: return "Open Settings"
        case .openPrivacy?: return "Open Privacy Settings"
        case nil: return nil
        }
    }
}
