import AppKit
import Combine
import IVYCore
import SwiftUI

/// The Face ID notch overlay. It runs in its own window because it must appear above the
/// lock screen (via `SkyLightSpace`), where IVY's regular notch panel can't go.
///
/// Like IVY's notch, the window never resizes: the black silhouette springs between the
/// hardware notch, a slim "armed" pill with a lock and Face ID mark, and the expanded scan.
@MainActor
final class FaceUnlockOverlay: ObservableObject {
    enum Phase: Equatable {
        /// Window visible, silhouette matches the hardware notch.
        case closed
        /// Waiting on the lock screen; hover to scan.
        case armed
        case scanning
        case success
        case failure
    }

    @Published private(set) var phase: Phase = .closed
    @Published private(set) var caption = "Face ID"
    @Published private(set) var geometry = NotchGeometry(screenFrame: .zero, hasNotch: false, notchWidth: 0,
                                                         topBandHeight: 32, centerX: 0)
    /// Bumped on each failure so the lock icon wiggles again.
    @Published private(set) var failureCount = 0

    /// Hovering the armed or failed overlay starts another scan.
    var onHoverRetry: (() -> Void)?

    private var panel: NSPanel?
    private var attachedToLockScreen = false
    private var generation = 0
    private let collapseDelay: TimeInterval = 0.45

    static let expandedWidth: CGFloat = 236
    static let expandedBody: CGFloat = 116
    static let armedWing: CGFloat = 34
    private static let canvas = CGSize(width: 360, height: 32 + 116 + 60)

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Shape

    var shapeSize: CGSize {
        let band = geometry.topBandHeight
        let notch = geometry.hasNotch ? geometry.notchWidth : 0
        switch phase {
        case .closed: return CGSize(width: geometry.hasNotch ? notch : 180, height: geometry.hasNotch ? band : 0)
        case .armed: return CGSize(width: max(notch, 120) + Self.armedWing * 2, height: band)
        case .scanning, .success, .failure:
            return CGSize(width: max(Self.expandedWidth, notch + 60), height: band + Self.expandedBody)
        }
    }

    var topRadius: CGFloat {
        switch phase {
        case .closed: return 0
        case .armed: return 6
        default: return NotchLayout.openTopRadius
        }
    }

    var bottomRadius: CGFloat {
        switch phase {
        case .closed: return 10
        case .armed: return 12
        default: return 30
        }
    }

    var isExpanded: Bool { phase == .scanning || phase == .success || phase == .failure }

    // MARK: - Transitions

    /// Shows the slim armed pill (lock screen only).
    func arm() {
        present { $0.phase = .armed }
    }

    func beginScan() {
        caption = "Face ID"
        present { $0.phase = .scanning }
    }

    func setHint(_ hint: FaceScanJudge.Hint?) {
        guard phase == .scanning else { return }
        switch hint {
        case .lookAtScreen?: caption = "Look at your Mac"
        case .blink?: caption = "Blink to unlock"
        case nil: caption = "Face ID"
        }
    }

    /// Plays the success or failure animation, then collapses (or returns to the armed pill).
    func finish(success: Bool, message: String? = nil, thenArm: Bool) {
        generation += 1
        let current = generation
        caption = message ?? (success ? "Unlocked" : "Not Recognized")
        phase = success ? .success : .failure
        if !success { failureCount += 1 }
        NSHapticFeedbackManager.defaultPerformer.perform(success ? .levelChange : .generic, performanceTime: .now)
        let hold: TimeInterval = success ? 1.5 : 2.6
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self, self.generation == current else { return }
            if thenArm { self.phase = .armed } else { self.hide() }
        }
    }

    /// Collapses into the notch, then orders the window out.
    func hide() {
        generation += 1
        let current = generation
        guard isVisible else { return }
        phase = .closed
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay) { [weak self] in
            guard let self, self.generation == current else { return }
            self.orderOut()
        }
    }

    /// The lock screen went away: return the window to normal window-server behavior.
    func detachFromLockScreen() {
        guard attachedToLockScreen, let panel else { return }
        SkyLightSpace.shared?.detach(panel)
        attachedToLockScreen = false
        updateMouseHandling()
    }

    func hoverChanged(_ hovering: Bool) {
        guard hovering, phase == .armed || phase == .failure else { return }
        onHoverRetry?()
    }

    // MARK: - Window

    /// Orders the window in at the closed notch first so SwiftUI has a frame to spring from.
    private func present(_ change: @escaping (FaceUnlockOverlay) -> Void) {
        generation += 1
        if isVisible {
            change(self)
            updateMouseHandling()
            return
        }
        refreshGeometry()
        phase = .closed
        let panel = panelIfNeeded()
        panel.setFrame(geometry.panelFrame(size: Self.canvas), display: true)
        panel.orderFrontRegardless()
        if LockScreenMonitor.isScreenLocked, let space = SkyLightSpace.shared {
            space.attach(panel)
            attachedToLockScreen = true
        }
        panel.displayIfNeeded()
        let current = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == current else { return }
            change(self)
            self.updateMouseHandling()
        }
    }

    private func orderOut() {
        detachFromLockScreen()
        panel?.orderOut(nil)
    }

    /// Mouse events only matter for hover-to-retry on the lock screen; otherwise clicks pass through.
    private func updateMouseHandling() {
        panel?.ignoresMouseEvents = !(attachedToLockScreen && (phase == .armed || phase == .failure || phase == .scanning))
    }

    private func refreshGeometry() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        geometry = NotchGeometry.make(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                      safeAreaTop: screen.safeAreaInsets.top,
                                      auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
                                      auxiliaryTopRight: screen.auxiliaryTopRightArea,
                                      scale: screen.backingScaleFactor)
    }

    private func panelIfNeeded() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.canvas),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        // Above the menu bar, full-screen apps and screen savers.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: FaceUnlockOverlayView(overlay: self))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }
}

/// SwiftUI content of the Face ID overlay.
struct FaceUnlockOverlayView: View {
    @ObservedObject var overlay: FaceUnlockOverlay

    private var glyphPhase: FaceIDGlyph.Phase {
        switch overlay.phase {
        case .closed, .armed: return .idle
        case .scanning: return .scanning
        case .success: return .success
        case .failure: return .failure
        }
    }

    var body: some View {
        let size = overlay.shapeSize
        let shape = NotchShape(topCornerRadius: overlay.topRadius, bottomCornerRadius: overlay.bottomRadius)
        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .shadow(color: .black.opacity(overlay.isExpanded ? 0.45 : 0), radius: 16, y: 6)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .onHover { overlay.hoverChanged($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: overlay.phase)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        let band = overlay.geometry.topBandHeight
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                lockIcon
                Spacer(minLength: 0)
                if overlay.phase == .armed {
                    FaceIDGlyph(state: .idle, size: band - 14, color: .white.opacity(0.9))
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .padding(.horizontal, overlay.phase == .armed ? 12 : NotchLayout.openTopRadius + 14)
            .frame(height: band)
            .opacity(overlay.phase == .closed ? 0 : 1)

            if overlay.isExpanded {
                VStack(spacing: 10) {
                    FaceIDGlyph(state: glyphPhase, size: 54)
                    Text(overlay.caption)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.2), value: overlay.caption)
                }
                .padding(.top, 8)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.1)),
                                        removal: .opacity.animation(.easeIn(duration: 0.12))))
            }
        }
    }

    private var lockIcon: some View {
        Image(systemName: overlay.phase == .success ? "lock.open.fill" : "lock.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
            .symbolEffect(.wiggle, value: overlay.failureCount)
            .animation(.smooth(duration: 0.35), value: overlay.phase == .success)
            .frame(width: 16)
    }
}
