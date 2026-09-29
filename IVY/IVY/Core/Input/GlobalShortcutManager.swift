import os
import AppKit
import CoreGraphics
import IVYCore

/// Watches the global modifier state and feeds `ModifierGestureStateMachine`.
///
/// Two strategies, chosen automatically:
/// 1. **Listen-only CGEventTap** (preferred) — event driven, zero idle cost. Needs the
///    *Input Monitoring* permission (not Accessibility: the tap can observe but never
///    modify or inject events).
/// 2. **Modifier polling** fallback — reads `CGEventSource.flagsState` 30×/s, which needs
///    no permission at all, so the gesture works out of the box. Chords with other keys
///    (⌘⌥Esc) can't be seen this way, so they're only filtered with strategy 1.
@MainActor
final class GlobalShortcutManager {
    enum Mode: String { case eventTap = "Event tap (Input Monitoring)", polling = "Modifier polling", stopped = "Stopped" }

    var onGesture: ((GestureEvent) -> Void)?
    var onEscape: (() -> Void)?
    /// Called for every chord press (before activation) so models can be pre-warmed.
    var onArmed: (() -> Void)?

    private(set) var mode: Mode = .stopped
    private var machine: ModifierGestureStateMachine
    private var shortcut: ActivationShortcut
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pollTimer: Timer?
    private var deadlineWork: DispatchWorkItem?
    private var localMonitor: Any?
    private var lastFlags: CGEventFlags = []

    init(shortcut: ActivationShortcut, configuration: GestureConfiguration) {
        self.shortcut = shortcut
        self.machine = ModifierGestureStateMachine(configuration: configuration)
    }

    func update(shortcut: ActivationShortcut, configuration: GestureConfiguration) {
        self.shortcut = shortcut
        machine.configuration = configuration
        reset()
    }

    func start() {
        stop()
        if CGPreflightListenEventAccess(), installEventTap() {
            mode = .eventTap
        } else {
            startPolling()
            mode = .polling
        }
        // Keys typed into IVY's own panel (text mode) arrive as local events.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.onEscape?() ; return nil }
                if self.mode != .eventTap { self.feed(.keyDown(at: event.timestamp)) }
            } else if self.mode != .eventTap {
                self.handle(flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
            }
            return event
        }
        Log.input.info("Global shortcut active via \(self.mode.rawValue, privacy: .public)")
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        pollTimer?.invalidate()
        pollTimer = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        deadlineWork?.cancel()
        mode = .stopped
    }

    /// Call when IVY is dismissed so a still-held chord doesn't immediately re-trigger.
    func reset() {
        machine.handle(.reset(snapshot(from: CGEventSource.flagsState(.combinedSessionState))))
        scheduleDeadline()
    }

    // MARK: - Event tap

    private func installEventTap() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userInfo).takeUnretainedValue()
            // The tap's run loop source is on the main run loop, so this is the main thread.
            MainActor.assumeIsolated { manager.handleTapEvent(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: CGEventMask(mask), callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.input.error("Couldn't create event tap")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables taps that respond slowly; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            handle(flags: event.flags)
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { onEscape?() }
            feed(.keyDown(at: ProcessInfo.processInfo.systemUptime))
        default:
            break
        }
    }

    // MARK: - Polling fallback

    private func startPolling() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let flags = CGEventSource.flagsState(.combinedSessionState)
                if flags != self.lastFlags { self.handle(flags: flags) }
            }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - State machine plumbing

    private func handle(flags: CGEventFlags) {
        lastFlags = flags
        let wasArmed = machine.state
        feed(.modifiers(snapshot(from: flags), at: ProcessInfo.processInfo.systemUptime))
        if case .modifierHoldDetected = machine.state, wasArmed == .idle { onArmed?() }
    }

    private func snapshot(from flags: CGEventFlags) -> ModifierSnapshot {
        let command = flags.contains(.maskCommand)
        let option = flags.contains(.maskAlternate)
        let control = flags.contains(.maskControl)
        let shift = flags.contains(.maskShift)
        switch shortcut {
        case .commandOption:
            return ModifierSnapshot(primary: command, secondary: option, other: control || shift)
        case .controlOption:
            return ModifierSnapshot(primary: control, secondary: option, other: command || shift)
        case .commandControl:
            return ModifierSnapshot(primary: command, secondary: control, other: option || shift)
        }
    }

    private func feed(_ input: GestureInput) {
        let events = machine.handle(input)
        scheduleDeadline()
        for event in events {
            Log.input.debug("Gesture event: \(String(describing: event), privacy: .public)")
            onGesture?(event)
        }
    }

    /// Schedules a tick exactly at the machine's next deadline (hold threshold or text toggle window).
    private func scheduleDeadline() {
        deadlineWork?.cancel()
        guard let deadline = machine.nextDeadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.feed(.tick(at: ProcessInfo.processInfo.systemUptime))
            }
        }
        deadlineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
