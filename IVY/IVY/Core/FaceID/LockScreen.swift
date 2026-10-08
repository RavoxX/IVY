import AppKit
import ApplicationServices
import CoreGraphics
import IVYCore
import os

/// Lock, unlock, sleep and wake signals for Face Unlock.
///
/// The distributed notifications can be posted by any process, so they only *trigger* work;
/// every decision re-checks `isScreenLocked`, which asks the window server directly.
@MainActor
final class LockScreenMonitor {
    enum Event { case locked, unlocked, wake, willSleep }

    var onEvent: ((Event) -> Void)?
    private(set) var isSleeping = false
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked") { $0.emit(.locked) }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.emit(.unlocked) }
        // Stands in for the key press that dismissed the screensaver, which Secure Event
        // Input hides from every app on the lock screen.
        observe(distributed, "com.apple.screensaver.didstop") { $0.emit(.wake) }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification.rawValue) { monitor in
            monitor.isSleeping = true
            monitor.emit(.willSleep)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observe(workspace, name.rawValue) { monitor in
                monitor.isSleeping = false
                monitor.emit(.wake)
            }
        }
    }

    /// Authoritative lock state from the window server. Fails closed (reports unlocked).
    nonisolated static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func observe(_ center: NotificationCenter, _ name: String, handler: @escaping @MainActor (LockScreenMonitor) -> Void) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { handler(self) } }
        }
        tokens.append((center, token))
    }

    private func emit(_ event: Event) {
        onEvent?(event)
    }
}

/// Types the stored login password into the lock screen's password field.
///
/// macOS has no API that lets a third-party app authorize a login, so (like Glance) this
/// posts keyboard events at the HID level, which needs Accessibility permission.
enum PasswordTyper {
    enum Failure: LocalizedError {
        case accessibility
        case events

        var errorDescription: String? {
            switch self {
            case .accessibility: return "Face ID needs Accessibility permission to type your password on the lock screen."
            case .events: return "Couldn't create keyboard events."
            }
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Clears the focused field, types `password` and presses Return. Blocking (~50 ms).
    static func type(_ password: Data) throws {
        guard isTrusted else { throw Failure.accessibility }
        guard let text = String(data: password, encoding: .utf8), !text.isEmpty else { throw Failure.events }
        let source = CGEventSource(stateID: .hidSystemState)
        // ⌘→ then ⌘⌫ removes stray keystrokes; both keys are layout independent (unlike ⌘A).
        try press(0x7C, command: true, source: source)
        try press(0x33, command: true, source: source)
        // Unicode events avoid keyboard-layout issues. Small batches: longer payloads get
        // truncated, and surrogate pairs must never be split.
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            var end = min(start + 20, units.count)
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
            let chunk = Array(units[start..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { throw Failure.events }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.004)
            up.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.004)
            start = end
        }
        try press(0x24, command: false, source: source)
    }

    private static func press(_ key: CGKeyCode, command: Bool, source: CGEventSource?) throws {
        let commandKey: CGKeyCode = 0x37
        if command {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true) else { throw Failure.events }
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.012)
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { throw Failure.events }
        down.flags = command ? .maskCommand : []
        up.flags = command ? .maskCommand : []
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
        if command {
            guard let release = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false) else { throw Failure.events }
            release.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.012)
        }
    }
}

/// Private SkyLight (window server) calls that put a window into a space above the lock
/// screen; there is no public API for this. Adapted from Lakr233/SkyLightWindow (MIT) via
/// Glance. Loaded dynamically: if Apple removes the symbols, `shared` is nil and Face Unlock
/// still works, just without the notch animation on the lock screen.
@MainActor
final class SkyLightSpace {
    static let shared = SkyLightSpace()

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias RemoveWindows = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private let connection: Int32
    private let space: Int32
    private let addWindows: AddWindows
    private let removeWindows: RemoveWindows

    private init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let main = dlsym(handle, "SLSMainConnectionID"), let create = dlsym(handle, "SLSSpaceCreate"),
              let level = dlsym(handle, "SLSSpaceSetAbsoluteLevel"), let show = dlsym(handle, "SLSShowSpaces"),
              let add = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces"), let remove = dlsym(handle, "SLSRemoveWindowsFromSpaces")
        else {
            Log.faceID.error("SkyLight unavailable; no lock screen overlay")
            return nil
        }
        connection = unsafeBitCast(main, to: MainConnection.self)()
        // Flag 1 matters: other values make Finder draw desktop icons into the space.
        space = unsafeBitCast(create, to: SpaceCreate.self)(connection, 1, 0)
        // 400 is the level Notification Center uses on the lock screen.
        _ = unsafeBitCast(level, to: SpaceSetLevel.self)(connection, space, 400)
        _ = unsafeBitCast(show, to: ShowSpaces.self)(connection, [space] as CFArray)
        addWindows = unsafeBitCast(add, to: AddWindows.self)
        removeWindows = unsafeBitCast(remove, to: RemoveWindows.self)
    }

    /// Call only while the screen is locked.
    func attach(_ window: NSWindow) {
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }

    func detach(_ window: NSWindow) {
        _ = removeWindows(connection, [window.windowNumber] as CFArray, [space] as CFArray)
    }
}
