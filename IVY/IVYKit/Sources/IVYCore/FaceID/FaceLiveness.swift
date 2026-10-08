import Foundation

/// Per-frame measurements for the liveness check, already reduced from Vision landmarks.
public struct LivenessSample: Equatable, Sendable {
    public var time: TimeInterval
    /// Mean eye height/width ratio; drops sharply during a blink.
    public var eyeOpenness: Double?
    public var yaw: Double?
    /// Horizontal nose offset from the eye midpoint divided by the eye distance. On a real
    /// (3D) face it follows tan(yaw); on a photo or screen it stays constant.
    public var noseOffset: Double?

    public init(time: TimeInterval, eyeOpenness: Double?, yaw: Double?, noseOffset: Double?) {
        self.time = time
        self.eyeOpenness = eyeOpenness
        self.yaw = yaw
        self.noseOffset = noseOffset
    }
}

public enum LivenessCue: String, Equatable, Sendable {
    case blink
    case headTurn
}

/// Light liveness gate: confirms a blink or a head turn whose nose parallax matches real
/// depth. It defeats a still photo, but not a video of the user (see Settings ▸ Face ID).
/// Once confirmed it stays confirmed for the scan.
public struct LivenessEvaluator: Sendable {
    public var window: TimeInterval = 2.5
    public private(set) var confirmedCue: LivenessCue?
    private var samples: [LivenessSample] = []

    public init() {}

    public var isConfirmed: Bool { confirmedCue != nil }

    public mutating func reset() {
        samples.removeAll()
        confirmedCue = nil
    }

    @discardableResult
    public mutating func observe(_ sample: LivenessSample) -> LivenessCue? {
        if let confirmedCue { return confirmedCue }
        samples.append(sample)
        samples.removeAll { sample.time - $0.time > window }
        if Self.detectsBlink(samples) {
            confirmedCue = .blink
        } else if Self.detectsDepthConsistentTurn(samples) {
            confirmedCue = .headTurn
        }
        return confirmedCue
    }

    /// A dip to under 65% of the open-eye baseline with open eyes shortly before and after.
    static func detectsBlink(_ samples: [LivenessSample]) -> Bool {
        let values = samples.compactMap(\.eyeOpenness)
        guard values.count >= 5, let baseline = values.max(), baseline > 0,
              let low = values.min(), let lowIndex = values.firstIndex(of: low) else { return false }
        guard low / baseline < 0.65, lowIndex > 0, lowIndex < values.count - 1 else { return false }
        let radius = 3
        let before = values[..<lowIndex].suffix(radius).contains { $0 / baseline > 0.75 }
        let after = values[(lowIndex + 1)...].prefix(radius).contains { $0 / baseline > 0.75 }
        return before && after
    }

    /// At least ~12° of yaw with the nose offset strongly correlated to tan(yaw). The sign of
    /// the correlation depends on the camera's yaw convention, so only its strength counts.
    static func detectsDepthConsistentTurn(_ samples: [LivenessSample]) -> Bool {
        let pairs = samples.compactMap { sample -> (Double, Double)? in
            guard let offset = sample.noseOffset, let yaw = sample.yaw else { return nil }
            return (offset, tan(yaw))
        }
        guard pairs.count >= 5 else { return false }
        let yaws = pairs.map { atan($0.1) }
        guard let minYaw = yaws.min(), let maxYaw = yaws.max(), maxYaw - minYaw >= 12 * .pi / 180 else { return false }
        guard let r = pearson(pairs.map(\.0), pairs.map(\.1)) else { return false }
        return abs(r) >= 0.8
    }

    static func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n, meanY = ys.reduce(0, +) / n
        var covariance = 0.0, varianceX = 0.0, varianceY = 0.0
        for i in 0..<xs.count {
            let dx = xs[i] - meanX, dy = ys[i] - meanY
            covariance += dx * dy
            varianceX += dx * dx
            varianceY += dy * dy
        }
        guard varianceX > 0, varianceY > 0 else { return nil }
        return covariance / (varianceX * varianceY).squareRoot()
    }
}
