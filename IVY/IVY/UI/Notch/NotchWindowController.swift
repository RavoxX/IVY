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

/// Positions the notch panel, resizes it with the content, and implements hover,
/// drag-to-shelf and click-outside behavior.
@MainActor
final class NotchWindowController {
    let panel = NotchPanel()
    private let model: NotchViewModel
    private let settings: SettingsStore
    private var cancellables: Set<AnyCancellable> = []
    private var monitors: [Any] = []
    private var shrinkWork: DispatchWorkItem?
    private var hoverOpenWork: DispatchWorkItem?
    private var hoverCloseWork: DispatchWorkItem?
    private var screen: NSScreen?
    private var currentWindowSize: CGSize = .zero

    init(model: NotchViewModel, settings: SettingsStore) {
        self.model = model
        self.settings = settings
        let hosting = FirstMouseHostingView(rootView: NotchRootView(model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting

        model.onKeyFocusChange = { [weak self] focus in self?.setKeyFocus(focus) }

        // Any published change may alter the shape size.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateFrame() }
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

    func relayout() {
        guard let screen = targetScreen() else { return }
        self.screen = screen
        let geometry = NotchGeometry.make(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                          safeAreaTop: screen.safeAreaInsets.top,
                                          auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
                                          auxiliaryTopRight: screen.auxiliaryTopRightArea)
        if geometry != model.geometry {
            Log.ui.info("Notch geometry: notch=\(geometry.hasNotch) width=\(Double(geometry.notchWidth)) band=\(Double(geometry.topBandHeight))")
            model.updateGeometry(geometry)
        }
        currentWindowSize = .zero
        updateFrame()
    }

    /// Re-targets the screen when following the mouse (called on activation).
    func prepareForActivation() {
        if settings.string(.displayPreference) == "mouse" { relayout() }
    }

    private func windowSize(for shape: CGSize) -> CGSize {
        guard shape.width > 0, shape.height > 0 else { return .zero }
        let margin = model.mode == .closed ? 0 : NotchLayout.shadowMargin
        return CGSize(width: shape.width + margin * 2, height: shape.height + margin)
    }

    /// Grows the window immediately (content animates inside) and shrinks it only after
    /// the closing animation, so nothing is ever clipped mid-animation. Keeping the
    /// window tight also means clicks next to the notch reach the apps below.
    private func updateFrame() {
        guard model.geometry.screenFrame != .zero else { return }
        let target = windowSize(for: model.shapeSize)
        let isGrowing = target.width > currentWindowSize.width || target.height > currentWindowSize.height

        if target == .zero {
            scheduleShrink(to: target)
            return
        }
        if isGrowing || !panel.isVisible {
            shrinkWork?.cancel()
            let size = CGSize(width: max(target.width, currentWindowSize.width),
                              height: max(target.height, currentWindowSize.height))
            apply(size)
            if target != size { scheduleShrink(to: target) }
        } else if target != currentWindowSize {
            scheduleShrink(to: target)
        }
    }

    private func scheduleShrink(to size: CGSize) {
        shrinkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let latest = self.windowSize(for: self.model.shapeSize)
                if latest == .zero {
                    self.panel.orderOut(nil)
                    self.currentWindowSize = .zero
                } else {
                    self.apply(latest)
                }
            }
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func apply(_ size: CGSize) {
        currentWindowSize = size
        let frame = model.geometry.panelFrame(size: size)
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    // MARK: - Focus

    private func setKeyFocus(_ focus: Bool) {
        if focus {
            panel.allowsKey = true
            updateFrame()
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

    /// Rect of the visible shape in screen coordinates.
    private func shapeRect(for size: CGSize) -> CGRect {
        model.geometry.panelFrame(size: size)
    }

    /// Hover target when closed: the notch (or a thin strip at the top edge without one).
    private var hotZone: CGRect {
        let geometry = model.geometry
        let width = max(geometry.hasNotch ? geometry.notchWidth : 160, model.shapeSize.width)
        let height = geometry.topBandHeight
        return geometry.panelFrame(size: CGSize(width: width, height: height)).insetBy(dx: -4, dy: -2)
    }

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
        switch model.mode {
        case .closed:
            guard hotZone.contains(location) else {
                hoverOpenWork?.cancel()
                hoverOpenWork = nil
                return
            }
            if dragging {
                // Dragging files onto the notch opens the shelf.
                let types = NSPasteboard(name: .drag).types ?? []
                if types.contains(.fileURL) { model.openDashboard(tab: .shelf) }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)

        case .dashboard:
            let inside = shapeRect(for: model.shapeSize).insetBy(dx: -10, dy: -10).contains(location)
            if inside {
                hoverCloseWork?.cancel()
                hoverCloseWork = nil
            } else if hoverCloseWork == nil, !dragging {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.hoverCloseWork = nil
                        let still = self.shapeRect(for: self.model.shapeSize).insetBy(dx: -10, dy: -10)
                        if !still.contains(NSEvent.mouseLocation) { self.model.closeDashboard() }
                    }
                }
                hoverCloseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }

        case .assistant:
            let inside = shapeRect(for: model.shapeSize).contains(location)
            if inside != model.isHovering { model.hoverChanged(inside) }
        }
    }

    private func mouseDownOutside() {
        guard model.isOpen else { return }
        if !shapeRect(for: model.shapeSize).contains(NSEvent.mouseLocation) {
            model.clickedOutside()
        }
    }
}
