import Foundation

/// Decides how a single Face Unlock scan resolves from per-frame results.
///
/// A match must coincide with a confirmed liveness check. A non-matching face only fails
/// the scan after `wrongFaceGrace` of consistent non-matches, because a wake often catches
/// the owner mid-glance. Frames without a face never fail the scan; it just times out.
public struct FaceScanJudge: Sendable {
    public enum Frame: Equatable, Sendable {
        case noFace
        case face(matched: Bool, live: Bool)
    }

    public enum Hint: Equatable, Sendable {
        /// No face for a while: look at the screen.
        case lookAtScreen
        /// Recognized, waiting for liveness: blink or turn slightly.
        case blink
    }

    public enum Verdict: Equatable, Sendable {
        case scanning(Hint?)
        case recognized
        case notRecognized
        case timedOut
    }

    public let startedAt: TimeInterval
    public let duration: TimeInterval
    public var wrongFaceGrace: TimeInterval = 2
    public var hintDelay: TimeInterval = 1.2

    private var wrongFaceSince: TimeInterval?
    private var noFaceSince: TimeInterval?
    private var matchedWaitingSince: TimeInterval?
    public private(set) var verdict: Verdict = .scanning(nil)

    public init(startedAt: TimeInterval, duration: TimeInterval) {
        self.startedAt = startedAt
        self.duration = duration
        noFaceSince = startedAt
    }

    public var isFinished: Bool {
        if case .scanning = verdict { return false }
        return true
    }

    @discardableResult
    public mutating func observe(_ frame: Frame, at time: TimeInterval) -> Verdict {
        guard !isFinished else { return verdict }
        switch frame {
        case .noFace:
            wrongFaceSince = nil
            matchedWaitingSince = nil
            if noFaceSince == nil { noFaceSince = time }
        case .face(let matched, let live):
            noFaceSince = nil
            if matched {
                wrongFaceSince = nil
                if live {
                    verdict = .recognized
                    return verdict
                }
                if matchedWaitingSince == nil { matchedWaitingSince = time }
            } else {
                matchedWaitingSince = nil
                if wrongFaceSince == nil { wrongFaceSince = time }
                if let since = wrongFaceSince, time - since >= wrongFaceGrace {
                    verdict = .notRecognized
                    return verdict
                }
            }
        }
        return tick(at: time)
    }

    /// Advances time without a new frame (for the timeout and hints).
    @discardableResult
    public mutating func tick(at time: TimeInterval) -> Verdict {
        guard !isFinished else { return verdict }
        if time - startedAt >= duration {
            verdict = .timedOut
            return verdict
        }
        if let since = matchedWaitingSince, time - since >= hintDelay {
            verdict = .scanning(.blink)
        } else if let since = noFaceSince, time - since >= hintDelay {
            verdict = .scanning(.lookAtScreen)
        } else {
            verdict = .scanning(nil)
        }
        return verdict
    }
}
