import Foundation

/// The two modifiers that form IVY's activation chord. `primary` is the key that is
/// released and pressed again to switch into text mode (Command by default).
public enum ActivationShortcut: String, CaseIterable, Codable, Sendable {
    case commandOption
    case controlOption
    case commandControl

    public var displayName: String {
        switch self {
        case .commandOption: return "⌘ Command + ⌥ Option"
        case .controlOption: return "⌃ Control + ⌥ Option"
        case .commandControl: return "⌘ Command + ⌃ Control"
        }
    }

    public var symbols: String {
        switch self {
        case .commandOption: return "⌘ ⌥"
        case .controlOption: return "⌃ ⌥"
        case .commandControl: return "⌘ ⌃"
        }
    }

    public var primarySymbol: String {
        switch self {
        case .commandOption, .commandControl: return "⌘"
        case .controlOption: return "⌃"
        }
    }
}

/// Modifier state reduced to what the gesture cares about.
public struct ModifierSnapshot: Equatable, Sendable {
    public var primary: Bool
    public var secondary: Bool
    /// Any modifier outside the chord (Shift, Control/Command, Fn, Caps Lock is ignored).
    public var other: Bool

    public init(primary: Bool = false, secondary: Bool = false, other: Bool = false) {
        self.primary = primary
        self.secondary = secondary
        self.other = other
    }

    public static let none = ModifierSnapshot()
    public var chordHeld: Bool { primary && secondary && !other }
    public var anyHeld: Bool { primary || secondary || other }
}

public enum GestureInput: Equatable, Sendable {
    /// Modifier flags changed (or were re-reported; duplicates are harmless).
    case modifiers(ModifierSnapshot, at: TimeInterval)
    /// A non-modifier key was pressed.
    case keyDown(at: TimeInterval)
    /// Timer callback for pending deadlines.
    case tick(at: TimeInterval)
    /// The app dismissed IVY (Escape, click outside, screen change…).
    case reset(ModifierSnapshot)
}

public enum GestureEvent: Equatable, Sendable {
    /// Chord held long enough: open IVY and start listening.
    case activateVoice
    /// Keys released: finalize the recording and transcribe it.
    case finishVoice
    /// Primary key re-pressed after activation: switch to typed input.
    case enterTextMode
}

public enum GestureState: Equatable, Sendable {
    case idle
    /// Chord is held; activation fires once `holdDuration` elapses.
    case modifierHoldDetected(since: TimeInterval)
    /// Voice capture is active.
    case listening
    /// Primary key was released; a re-press before `deadline` switches to text mode.
    case waitingForTextToggle(deadline: TimeInterval)
}

public struct GestureConfiguration: Equatable, Sendable {
    public var holdDuration: TimeInterval
    public var textToggleWindow: TimeInterval

    public init(holdDuration: TimeInterval = 0.5, textToggleWindow: TimeInterval = 0.5) {
        self.holdDuration = holdDuration
        self.textToggleWindow = textToggleWindow
    }
}

/// Explicit state machine for the modifier-only activation gesture.
///
/// * Hold chord ≥ `holdDuration` (0.5 s by default) → `.activateVoice`; release → `.finishVoice`.
/// * Hold chord, then release the primary key and press it again within
///   `textToggleWindow` → `.enterTextMode`.
/// * Quick taps, single modifiers and chords used with another key (⌘⌥Esc, ⌘⌥D…) do nothing.
///
/// Time is injected so the machine is fully deterministic and unit-testable; the
/// `GlobalShortcutManager` schedules `.tick` inputs at `nextDeadline`.
public struct ModifierGestureStateMachine: Sendable {
    public private(set) var state: GestureState = .idle
    public var configuration: GestureConfiguration

    /// Timers fire at the deadline; tolerate floating-point error so a tick at exactly
    /// `since + holdDuration` always activates.
    static let epsilon: TimeInterval = 0.001

    private var current = ModifierSnapshot.none
    /// After a gesture completes (or a chord is used with another key) the user must
    /// release every modifier before the chord can arm again. Prevents re-triggering
    /// while keys are still down, e.g. right after entering text mode.
    private var requiresRelease = false

    public init(configuration: GestureConfiguration = GestureConfiguration()) {
        self.configuration = configuration
    }

    public var nextDeadline: TimeInterval? {
        switch state {
        case .modifierHoldDetected(let since): return since + configuration.holdDuration
        case .waitingForTextToggle(let deadline): return deadline
        case .idle, .listening: return nil
        }
    }

    @discardableResult
    public mutating func handle(_ input: GestureInput) -> [GestureEvent] {
        switch input {
        case .reset(let snapshot):
            state = .idle
            current = snapshot
            requiresRelease = snapshot.anyHeld
            return []

        case .tick(let time):
            return advance(to: time)

        case .keyDown(let time):
            let events = advance(to: time)
            if case .modifierHoldDetected = state {
                // The chord is part of a normal shortcut (⌘⌥Esc etc.); not for IVY.
                state = .idle
                requiresRelease = true
            }
            return events

        case .modifiers(let snapshot, let time):
            // Fire any deadline that passed before this event arrived.
            var events = advance(to: time)
            let previous = current
            current = snapshot
            events += transition(from: previous, to: snapshot, at: time)
            return events
        }
    }

    // MARK: - Private

    private mutating func advance(to time: TimeInterval) -> [GestureEvent] {
        switch state {
        case .modifierHoldDetected(let since) where time - since >= configuration.holdDuration - Self.epsilon:
            if current.chordHeld {
                state = .listening
                return [.activateVoice]
            }
            state = .idle
            return []

        case .waitingForTextToggle(let deadline) where time >= deadline - Self.epsilon:
            if current.secondary && !current.primary {
                // Still holding the secondary key: keep listening until it is released.
                state = .listening
                return []
            }
            state = .idle
            requiresRelease = current.anyHeld
            return [.finishVoice]

        default:
            return []
        }
    }

    private mutating func transition(from previous: ModifierSnapshot, to snapshot: ModifierSnapshot,
                                     at time: TimeInterval) -> [GestureEvent] {
        switch state {
        case .idle:
            if requiresRelease {
                if !snapshot.primary && !snapshot.secondary { requiresRelease = false }
                return []
            }
            // ⌘⇧⌥-style shortcuts belong to other apps: wait for a full release.
            if snapshot.other && (snapshot.primary || snapshot.secondary) {
                requiresRelease = true
                return []
            }
            // Arm only on the transition into the chord, never while other modifiers are down.
            if snapshot.chordHeld && !previous.chordHeld {
                state = .modifierHoldDetected(since: time)
            }
            return []

        case .modifierHoldDetected:
            if !snapshot.chordHeld {
                // Quick tap or an extra modifier joined: ignore the gesture.
                state = .idle
                requiresRelease = snapshot.other
            }
            return []

        case .listening:
            if previous.primary && !snapshot.primary {
                state = .waitingForTextToggle(deadline: time + configuration.textToggleWindow)
                return []
            }
            if !snapshot.primary && !snapshot.secondary {
                state = .idle
                return [.finishVoice]
            }
            return []

        case .waitingForTextToggle:
            if !previous.primary && snapshot.primary {
                state = .idle
                requiresRelease = true
                return [.enterTextMode]
            }
            return []
        }
    }
}
