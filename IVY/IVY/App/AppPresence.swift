import AppKit

/// IVY is an accessory (menu bar) app, and macOS leaves accessory apps out of ⌘-Tab and the
/// Dock. A window such as Settings would get stranded behind other apps as soon as one of
/// them came forward. While one of IVY's own windows is open, IVY therefore becomes a
/// regular app (Dock icon, ⌘-Tab, its menu bar) and returns to accessory when the last
/// window closes. The notch and menu bar item work the same either way.
@MainActor
enum AppPresence {
    private static var windows: [NSWindow] = []
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Shows `window` in front and keeps IVY switchable while it's open.
    static func show(_ window: NSWindow) {
        track(window)
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private static func track(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard observers[id] == nil else { return }
        windows.append(window)
        observers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                               queue: .main) { _ in
            MainActor.assumeIsolated { closed(window) }
        }
    }

    private static func closed(_ window: NSWindow) {
        // The window is still visible during willClose; decide once it's gone.
        DispatchQueue.main.async {
            guard !windows.contains(where: { $0 !== window && $0.isVisible }) else { return }
            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
