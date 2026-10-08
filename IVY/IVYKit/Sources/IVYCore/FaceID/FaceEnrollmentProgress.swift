import Foundation

/// Guided enrollment like Face ID's setup: look straight ahead, then move your head slowly
/// in a circle while a ring of ticks fills in the direction you're facing.
///
/// Pure state; the app feeds head pose per frame and stores the frame's embedding whenever
/// `observe` returns a capture.
public struct FaceEnrollmentProgress: Equatable, Sendable {
    public static let tickCount = 60
    public static let directionCount = 8
    public static let centerSamplesNeeded = 3

    /// How far (degrees) the head must turn before a direction counts.
    public var turnThreshold: Double = 10
    /// Within this many degrees of straight ahead counts as centered.
    public var centerTolerance: Double = 8
    public var minimumQuality: Float = 0.3

    public private(set) var centerSamples = 0
    public private(set) var capturedDirections: Set<Int> = []
    public private(set) var litTicks: Set<Int> = []

    public enum Phase: Equatable, Sendable { case centering, turning, complete }

    public enum Capture: Equatable, Sendable {
        case center
        case direction(Int)
    }

    public init() {}

    public var phase: Phase {
        if centerSamples < Self.centerSamplesNeeded { return .centering }
        return capturedDirections.count < Self.directionCount ? .turning : .complete
    }

    public var isComplete: Bool { phase == .complete }

    /// 0...1 fill of the ring (center capture counts for the first slice).
    public var fraction: Double {
        let center = Double(centerSamples) / Double(Self.centerSamplesNeeded) * 0.1
        let ring = Double(litTicks.count) / Double(Self.tickCount) * 0.45
            + Double(capturedDirections.count) / Double(Self.directionCount) * 0.45
        return isComplete ? 1 : min(0.99, center + ring)
    }

    /// - Parameters:
    ///   - yaw: degrees, positive when the head turns toward the right side of the (mirrored) preview.
    ///   - pitch: degrees, positive when the head tilts up.
    /// - Returns: what to store this frame's embedding as, or nil to discard it.
    public mutating func observe(yaw: Double, pitch: Double, quality: Float?) -> Capture? {
        let goodQuality = (quality ?? 1) >= minimumQuality
        let magnitude = (yaw * yaw + pitch * pitch).squareRoot()

        if phase == .centering {
            guard goodQuality, abs(yaw) <= centerTolerance, abs(pitch) <= centerTolerance else { return nil }
            centerSamples += 1
            return .center
        }
        guard phase == .turning, magnitude >= turnThreshold else { return nil }

        let angle = Self.angle(yaw: yaw, pitch: pitch)
        let tick = Self.tick(for: angle)
        // Light a small arc so the ring fills smoothly instead of one tick at a time.
        for offset in -3...3 { litTicks.insert((tick + offset + Self.tickCount) % Self.tickCount) }

        let direction = Self.direction(for: angle)
        guard goodQuality, !capturedDirections.contains(direction) else { return nil }
        capturedDirections.insert(direction)
        // Fill the whole slice of a captured direction.
        let perDirection = Self.tickCount / Self.directionCount
        let first = direction * perDirection - perDirection / 2
        for offset in 0...perDirection { litTicks.insert((first + offset + Self.tickCount) % Self.tickCount) }
        if isComplete { litTicks = Set(0..<Self.tickCount) }
        return .direction(direction)
    }

    /// Radians in 0..<2π, counter-clockwise from "right", y up.
    public static func angle(yaw: Double, pitch: Double) -> Double {
        let raw = atan2(pitch, yaw)
        return raw < 0 ? raw + 2 * .pi : raw
    }

    public static func tick(for angle: Double) -> Int {
        Int((angle / (2 * .pi) * Double(tickCount)).rounded()) % tickCount
    }

    public static func direction(for angle: Double) -> Int {
        Int((angle / (2 * .pi) * Double(directionCount)).rounded()) % directionCount
    }
}
