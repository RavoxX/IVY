import IVYCore
import SwiftUI

/// SwiftUI content of the notch panel. It only positions content at its final size; the
/// notch silhouette, blur and the spring animation live in `NotchContainerView`
/// (Core Animation), which masks this view.
struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel

    /// Content fades in while the shape grows, and out quickly on close.
    private var reveal: AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.08)),
                    removal: .opacity.animation(.easeIn(duration: 0.1)))
    }

    var body: some View {
        content
            .frame(width: model.contentWidth, height: model.mode == .assistant ? nil : model.shapeSize.height, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .closed:
            if model.showsLiveActivity {
                LiveActivityView(model: model, music: model.env.music, timers: model.env.timers)
                    .transition(.opacity.animation(.easeOut(duration: 0.25).delay(0.15)))
            }
        case .dashboard:
            DashboardView(model: model).transition(reveal)
        case .assistant:
            if model.writingAssistVisible {
                WritingAssistView(model: model, service: model.env.writingAssist).transition(reveal)
            } else {
                AssistantView(model: model).transition(reveal)
            }
        }
    }
}

// MARK: - Closed live activity

/// Closed-notch live activity: album art (or a timer icon) on the left wing, audio bars
/// (or the timer countdown) on the right wing.
struct LiveActivityView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var music: MusicController
    @ObservedObject var timers: TimerService

    var body: some View {
        let band = model.geometry.topBandHeight
        HStack(spacing: 0) {
            Group {
                if music.isPlaying {
                    ArtworkView(url: music.state?.artworkURL, size: band - 10, cornerRadius: 5)
                } else if timers.next != nil {
                    Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
                }
            }
            .padding(.leading, NotchLayout.openTopRadius)
            Spacer(minLength: 0)
            if let next = timers.next {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(DurationParser.countdown(next.remaining(at: context.date)))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                }
                .padding(.trailing, NotchLayout.openTopRadius + 2)
            } else {
                AudioBarsView(isAnimating: music.state?.status == .playing)
                    .frame(width: 14, height: band - 16)
                    .padding(.trailing, NotchLayout.openTopRadius + 4)
            }
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

            // AppKit-backed ScrollViews ignore SwiftUI masks (they'd poke out of the notch
            // while it animates), so only scroll when the content really overflows.
            if model.assistantBodyHeight > NotchLayout.maxAssistantBody {
                ScrollView(.vertical, showsIndicators: false) { measuredBody }
                    .frame(height: NotchLayout.maxAssistantBody)
            } else {
                measuredBody
            }
        }
        .onPreferenceChange(BodyHeightKey.self) { height in
            if abs(model.assistantBodyHeight - height) > 0.5 { model.assistantBodyHeight = height }
        }
    }
}

extension AssistantView {
    var measuredBody: some View {
        AssistantBody(model: model)
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 14)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: BodyHeightKey.self, value: proxy.size.height)
            })
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
            Button { model.env.openSettings(section: "assistant") } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10))
            }.buttonStyle(.plain).help("Continue in the assistant window")
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
            let choice = model.activeModelChoice
            Text(choice.provider.displayName + " · " + choice.model)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            switch model.phase {
            case .listening:
                ListeningView(level: model.audioLevel, shortcut: model.env.settings.activationShortcut)
            default:
                RingingView(service: model.env.timers) { model.stopButtonTapped() }
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
                    WorkingChip(label: label, done: model.workingDone, failed: model.workingFailed)
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
            if model.answer.isEmpty { LoadingView(text: "Waiting for " + model.activeModelChoice.provider.displayName + "…") }
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
