import CoreGraphics
import Foundation

/// Landmark alignment for ArcFace, which expects faces warped into a canonical 112×112 pose.
public enum FaceAlignment {
    public static let outputSize = 112

    /// Standard ArcFace template in top-left/y-down pixels: left eye, right eye, nose tip,
    /// left mouth corner, right mouth corner (left/right as seen in the image).
    public static let referencePoints: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// Least-squares similarity transform (uniform scale, rotation, translation) mapping
    /// `source` onto `destination`. Nil for fewer than two pairs or degenerate input.
    public static func similarityTransform(from source: [CGPoint], to destination: [CGPoint]) -> CGAffineTransform? {
        guard source.count == destination.count, source.count >= 2 else { return nil }
        let n = CGFloat(source.count)
        let sourceMean = CGPoint(x: source.map(\.x).reduce(0, +) / n, y: source.map(\.y).reduce(0, +) / n)
        let destinationMean = CGPoint(x: destination.map(\.x).reduce(0, +) / n, y: destination.map(\.y).reduce(0, +) / n)

        // Treat points as complex numbers: the optimal s·e^{iθ} is Σ q·conj(p) / Σ |p|².
        var real: CGFloat = 0, imaginary: CGFloat = 0, denominator: CGFloat = 0
        for (s, d) in zip(source, destination) {
            let p = CGPoint(x: s.x - sourceMean.x, y: s.y - sourceMean.y)
            let q = CGPoint(x: d.x - destinationMean.x, y: d.y - destinationMean.y)
            real += q.x * p.x + q.y * p.y
            imaginary += q.y * p.x - q.x * p.y
            denominator += p.x * p.x + p.y * p.y
        }
        guard denominator > 0 else { return nil }
        let a = real / denominator, b = imaginary / denominator
        let tx = destinationMean.x - (a * sourceMean.x - b * sourceMean.y)
        let ty = destinationMean.y - (b * sourceMean.x + a * sourceMean.y)
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }
}
