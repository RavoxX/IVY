import Foundation

/// Waits for selection gestures to finish and the selected field/range to settle.
/// Uses a monotonic clock supplied by the caller, so polling and input events share
/// the same debounce without relying on wall-clock time or running timers in tests.
public struct WritingSelectionSettler<Selection: Equatable> {
    public let delay: TimeInterval
    private var candidate: Selection?
    private var stableSince: TimeInterval?

    public init(delay: TimeInterval = 0.25) { self.delay = delay }

    public mutating func reset() {
        candidate = nil
        stableSince = nil
    }

    public mutating func shouldShow(selection: Selection?, isSelecting: Bool, at time: TimeInterval) -> Bool {
        guard !isSelecting, let selection, time.isFinite else { reset(); return false }
        guard candidate == selection, let since = stableSince, time >= since else {
            candidate = selection
            stableSince = time
            return false
        }
        return time - since >= delay
    }
}
