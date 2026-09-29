import Testing
@testable import IVYCore

/// Drives the machine the way GlobalShortcutManager does: modifier changes plus ticks at deadlines.
private struct Driver {
    var machine = ModifierGestureStateMachine(configuration: GestureConfiguration(holdDuration: 1.0, textToggleWindow: 0.5))
    var events: [GestureEvent] = []

    mutating func keys(_ primary: Bool, _ secondary: Bool, other: Bool = false, at time: Double) {
        events += machine.handle(.modifiers(ModifierSnapshot(primary: primary, secondary: secondary, other: other), at: time))
    }

    mutating func tick(_ time: Double) {
        events += machine.handle(.tick(at: time))
    }

    mutating func keyDown(_ time: Double) {
        events += machine.handle(.keyDown(at: time))
    }
}

@Suite("ModifierGestureStateMachine")
struct GestureStateMachineTests {
    @Test("1. Hold ⌘⌥ ≥ 1 s → voice mode, release → finish")
    func holdActivatesVoice() {
        var d = Driver()
        d.keys(true, false, at: 0.00)
        d.keys(true, true, at: 0.05)
        #expect(d.machine.state == .modifierHoldDetected(since: 0.05))
        #expect(d.machine.nextDeadline == 1.05)
        d.tick(1.05)
        #expect(d.events == [.activateVoice])
        #expect(d.machine.state == .listening)

        // Natural release: Command first, then Option shortly after.
        d.keys(false, true, at: 3.00)
        d.keys(false, false, at: 3.04)
        #expect(d.events == [.activateVoice]) // waiting for a possible text toggle
        d.tick(3.50)
        #expect(d.events == [.activateVoice, .finishVoice])
        #expect(d.machine.state == .idle)
    }

    @Test("2. Hold, release ⌘, press ⌘ again quickly → text mode")
    func releaseAndRepressEntersTextMode() {
        var d = Driver()
        d.keys(true, true, at: 0)
        d.tick(1.0)
        d.keys(false, true, at: 1.3)   // release Command, keep Option
        #expect(d.machine.state == .waitingForTextToggle(deadline: 1.8))
        d.keys(true, true, at: 1.5)    // press Command again
        #expect(d.events == [.activateVoice, .enterTextMode])
        #expect(d.machine.state == .idle)
    }

    @Test("2b. Text toggle also works after releasing both keys")
    func textModeAfterFullRelease() {
        var d = Driver()
        d.keys(true, true, at: 0)
        d.tick(1.0)
        d.keys(false, false, at: 1.2)
        d.keys(true, false, at: 1.45)
        #expect(d.events == [.activateVoice, .enterTextMode])
    }

    @Test("2c. Re-press after the window closes does not enter text mode")
    func latePressDoesNotToggle() {
        var d = Driver()
        d.keys(true, true, at: 0)
        d.tick(1.0)
        d.keys(false, false, at: 1.2)
        d.tick(1.7)
        d.keys(true, false, at: 1.9)
        #expect(d.events == [.activateVoice, .finishVoice])
    }

    @Test("3. Quick tap of both modifiers → nothing")
    func quickTapDoesNothing() {
        var d = Driver()
        d.keys(true, true, at: 0)
        d.keys(false, false, at: 0.25)
        d.tick(1.0)
        d.tick(2.0)
        #expect(d.events.isEmpty)
        #expect(d.machine.state == .idle)
    }

    @Test("4. Only Command → nothing")
    func onlyPrimaryDoesNothing() {
        var d = Driver()
        d.keys(true, false, at: 0)
        d.tick(1.5)
        d.keys(false, false, at: 2)
        #expect(d.events.isEmpty)
        #expect(d.machine.nextDeadline == nil)
    }

    @Test("5. Only Option → nothing")
    func onlySecondaryDoesNothing() {
        var d = Driver()
        d.keys(false, true, at: 0)
        d.tick(1.5)
        d.keys(false, false, at: 2)
        #expect(d.events.isEmpty)
    }

    @Test("Chord used with another key (⌘⌥Esc) is ignored until released")
    func keyChordCancels() {
        var d = Driver()
        d.keys(true, true, at: 0)
        d.keyDown(0.3)
        d.tick(1.0)
        #expect(d.events.isEmpty)
        // Still holding: must not re-arm until everything is released.
        d.keys(true, true, at: 1.2)
        d.tick(2.5)
        #expect(d.events.isEmpty)
        d.keys(false, false, at: 3)
        d.keys(true, true, at: 3.1)
        d.tick(4.1) // exactly at the deadline (floating point: 4.1 - 3.1 < 1.0)
        #expect(d.events == [.activateVoice])
    }

    @Test("Extra modifier (Shift) prevents arming")
    func otherModifierBlocks() {
        var d = Driver()
        d.keys(true, true, other: true, at: 0)
        d.tick(1.5)
        #expect(d.events.isEmpty)
        d.keys(true, true, at: 0.2) // Shift released while holding: still needs full release
        d.tick(2.0)
        #expect(d.events.isEmpty)
    }

    @Test("Duplicate modifier reports (key repeat) are harmless")
    func duplicateReports() {
        var d = Driver()
        d.keys(true, true, at: 0)
        d.keys(true, true, at: 0.4)
        d.keys(true, true, at: 0.8)
        #expect(d.machine.state == .modifierHoldDetected(since: 0))
        d.tick(1.0)
        d.keys(true, true, at: 1.4)
        #expect(d.events == [.activateVoice])
        #expect(d.machine.state == .listening)
    }

    @Test("Deadline passed without a tick is applied on the next modifier event")
    func lateTickHandledByNextEvent() {
        var d = Driver()
        d.keys(true, true, at: 0)
        // Timer was delayed; the release arrives at 1.3 s.
        d.keys(false, false, at: 1.3)
        #expect(d.events == [.activateVoice])
        #expect(d.machine.state == .waitingForTextToggle(deadline: 1.8))
    }

    @Test("Keeping Option held after releasing Command keeps listening")
    func optionHeldKeepsListening() {
        var d = Driver()
        d.keys(true, true, at: 0)
        d.tick(1.0)
        d.keys(false, true, at: 2.0)
        d.tick(2.5)
        #expect(d.machine.state == .listening)
        #expect(d.events == [.activateVoice])
        d.keys(false, false, at: 4.0)
        #expect(d.events == [.activateVoice, .finishVoice])
    }

    @Test("No re-activation while keys stay down after text mode")
    func noRetriggerAfterTextMode() {
        var d = Driver()
        d.keys(true, true, at: 0)
        d.tick(1.0)
        d.keys(false, true, at: 1.2)
        d.keys(true, true, at: 1.3)
        d.tick(3.0)
        #expect(d.events == [.activateVoice, .enterTextMode])
    }

    @Test("Reset returns to idle and requires release")
    func resetBehaviour() {
        var d = Driver()
        d.keys(true, true, at: 0)
        d.tick(1.0)
        d.events += d.machine.handle(.reset(ModifierSnapshot(primary: true, secondary: true)))
        #expect(d.machine.state == .idle)
        d.tick(5)
        #expect(d.events == [.activateVoice])
    }

    @Test("Default configuration activates after 0.5 s")
    func defaultHoldIsHalfASecond() {
        var machine = ModifierGestureStateMachine()
        #expect(machine.configuration.holdDuration == 0.5)
        machine.handle(.modifiers(ModifierSnapshot(primary: true, secondary: true), at: 10))
        #expect(machine.handle(.tick(at: 10.3)).isEmpty)
        #expect(machine.handle(.tick(at: 10.5)) == [.activateVoice])
    }
}
