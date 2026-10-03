import os
import AppKit
import Combine
import IVYCore
import SwiftUI

/// Borderless, non-activating panel that sits above the menu bar at the notch.
/// It can become key (for text input) without activating IVY or stealing the
/// frontmost app's menu bar.
final class NotchPanel: NSPanel {
    var allowsKey = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above the menu bar so the panel can grow out of the notch.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that reacts to the first click even though IVY isn't the active app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Positions the notch panel and implements hover, drag-to-shelf and click-outside.
///
/// The window has a **fixed size** large enough for every state and never resizes; the
/// black shape inside animates with SwiftUI. That keeps the spring animation smooth and
/// truly "out of the notch". Clicks outside the visible shape pass through because the
/// panel only accepts mouse events while the pointer is over the shape.
@MainActor
final class NotchWindowController {
    let panel = NotchPanel()
    private let container: NotchContainerView
    private let model: NotchViewModel
    private let settings: SettingsStore
    private var cancellables: Set<AnyCancellable> = []
    private var monitors: [Any] = []
    private var hoverOpenWork: DispatchWorkItem?
    private var hoverCloseWork: DispatchWorkItem?

    static let canvasSize = CGSize(width: NotchLayout.dashboardWidth + NotchLayout.shadowMargin * 2,
                                   height: 40 + NotchLayout.maxAssistantBody + NotchLayout.shadowMargin + 40)

    init(model: NotchViewModel, settings: SettingsStore) {
        self.model = model
        self.settings = settings
        let hosting = FirstMouseHostingView(rootView: NotchRootView(model: model))
        hosting.sizingOptions = []
        container = NotchContainerView(content: hosting)
        panel.contentView = container

        model.onKeyFocusChange = { [weak self] focus in self?.setKeyFocus(focus) }
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateShape(animated: true)
                    self?.updateMouseHandling()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)

        installMouseMonitors()
        relayout()
    }

    // MARK: - Screen & geometry

    /// Built-in notched display if available (default), otherwise the main screen.
    private func targetScreen() -> NSScreen? {
        switch settings.string(.displayPreference) {
        case "main":
            return NSScreen.main ?? NSScreen.screens.first
        case "mouse":
            let location = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
        default:
            return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
        }
    }

    /// Recomputes the notch geometry (monitor, resolution or arrangement changed).
    func relayout() {
        guard let screen = targetScreen() else { return }
        let geometry = NotchGeometry.make(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                          safeAreaTop: screen.safeAreaInsets.top,
                                          auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
                                          auxiliaryTopRight: screen.auxiliaryTopRightArea,
                                          scale: screen.backingScaleFactor)
        if geometry != model.geometry {
            Log.ui.info("Notch geometry: notch=\(geometry.hasNotch) width=\(Double(geometry.notchWidth)) band=\(Double(geometry.topBandHeight))")
            model.updateGeometry(geometry)
        }
        panel.setFrame(geometry.panelFrame(size: Self.canvasSize), display: true)
        panel.orderFrontRegardless()
        container.layoutSubtreeIfNeeded()
        updateShape(animated: false)
        updateMouseHandling()
    }

    /// Springs the Core Animation notch shape to the model's current size.
    private func updateShape(animated: Bool) {
        if model.workspaceVisible { panel.orderOut(nil); return }
        panel.orderFrontRegardless()
        container.apply(NotchContainerView.Spec(size: model.shapeSize, topRadius: model.topRadius,
                                                bottomRadius: model.bottomRadius, band: model.geometry.topBandHeight,
                                                isOpen: model.isOpen),
                        animated: animated)
    }

    /// Re-targets the screen when following the mouse (called on activation).
    func prepareForActivation() {
        if settings.string(.displayPreference) == "mouse" { relayout() }
    }

    /// Rect of the visible shape in screen coordinates.
    private var shapeRect: CGRect {
        model.geometry.panelFrame(size: model.shapeSize)
    }

    /// Hover target when closed: the notch (or a thin strip at the top edge without one).
    private var hotZone: CGRect {
        let geometry = model.geometry
        let width = max(geometry.hasNotch ? geometry.notchWidth : 160, model.shapeSize.width)
        return geometry.panelFrame(size: CGSize(width: width, height: geometry.topBandHeight)).insetBy(dx: -4, dy: -2)
    }

    /// The panel only takes mouse events while the pointer is over the visible shape.
    private func updateMouseHandling(location: CGPoint = NSEvent.mouseLocation) {
        let inside = !model.workspaceVisible && model.isOpen && shapeRect.contains(location)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }

    // MARK: - Focus

    private func setKeyFocus(_ focus: Bool) {
        if focus {
            panel.allowsKey = true
            panel.ignoresMouseEvents = false
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.allowsKey = false
            if panel.isKeyWindow {
                // Hand keyboard focus back to the previously active app.
                panel.resignKey()
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }
    }

    // MARK: - Mouse: hover, drag-to-shelf, click outside

    private func installMouseMonitors() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        // Global mouse monitors don't require any permission.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved(dragging: event.type == .leftMouseDragged) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moveMask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved(dragging: event.type == .leftMouseDragged) }
            return event
        }) { monitors.append(local) }
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDownOutside() }
        }) { monitors.append(clicks) }
    }

    private func mouseMoved(dragging: Bool) {
        let location = NSEvent.mouseLocation
        updateMouseHandling(location: location)
        switch model.mode {
        case .closed:
            guard hotZone.contains(location) else {
                hoverOpenWork?.cancel()
                hoverOpenWork = nil
                return
            }
            if dragging {
                // Dragging files onto the notch opens the shelf.
                if (NSPasteboard(name: .drag).types ?? []).contains(.fileURL) {
                    model.openDashboard(tab: .shelf)
                    panel.ignoresMouseEvents = false
                }
                return
            }
            guard settings.bool(.openOnHover), !settings.bool(.paused), hoverOpenWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hoverOpenWork = nil
                    if self.hotZone.contains(NSEvent.mouseLocation) { self.model.openDashboard() }
                }
            }
            hoverOpenWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)

        case .dashboard:
            let inside = shapeRect.insetBy(dx: -10, dy: -10).contains(location)
            if inside {
                hoverCloseWork?.cancel()
                hoverCloseWork = nil
            } else if hoverCloseWork == nil, !dragging {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.hoverCloseWork = nil
                        if !self.shapeRect.insetBy(dx: -10, dy: -10).contains(NSEvent.mouseLocation) {
                            self.model.closeDashboard()
                        }
                    }
                }
                hoverCloseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }

        case .assistant:
            let inside = shapeRect.contains(location)
            if inside != model.isHovering { model.hoverChanged(inside) }
        }
    }

    private func mouseDownOutside() {
        guard model.isOpen, !shapeRect.contains(NSEvent.mouseLocation) else { return }
        model.clickedOutside()
    }
}
