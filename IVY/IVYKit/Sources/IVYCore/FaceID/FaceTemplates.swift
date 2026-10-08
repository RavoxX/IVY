import Foundation

/// Vector math for face embeddings (ArcFace produces 512 floats per face).
public enum FaceVector {
    /// Scales `vector` to unit length. Zero vectors are returned unchanged.
    public static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Cosine similarity in -1...1; 0 for empty or mismatched vectors.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Normalizes each vector before averaging so one large-magnitude sample can't dominate,
    /// then renormalizes the mean. Vectors with a different length than the first are skipped.
    public static func average(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        let usable = vectors.filter { $0.count == first.count }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in usable {
            let unit = normalized(vector)
            for i in 0..<unit.count { sum[i] += unit[i] }
        }
        return normalized(sum.map { $0 / Float(usable.count) })
    }
}

/// One enrolled appearance (e.g. "Me", "Me with glasses"). Only embeddings are stored,
/// never images, and the whole list is encrypted at rest by the app.
public struct FaceTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var samples: [[Float]]
    /// The embedder that produced `samples`. Embeddings of different models live in unrelated
    /// vector spaces, so a template from another model never matches.
    public var modelIdentifier: String
    public var createdAt: Date
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, samples: [[Float]], modelIdentifier: String,
                createdAt: Date = Date(), isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.samples = samples
        self.modelIdentifier = modelIdentifier
        self.createdAt = createdAt
        self.isEnabled = isEnabled
    }

    public var centroid: [Float]? { FaceVector.average(samples) }
}

/// How close a face must be to an enrolled template. Thresholds are cosine similarities for
/// ArcFace (w600k_mbf) and were tuned by Glance (github.com/jonnyoo/glance).
public enum FaceMatchStrictness: String, CaseIterable, Identifiable, Sendable {
    case relaxed, standard, strict

    public var id: String { rawValue }

    public var threshold: Float {
        switch self {
        case .relaxed: return 0.58
        case .standard: return 0.66
        case .strict: return 0.74
        }
    }

    public var title: String {
        switch self {
        case .relaxed: return "Relaxed"
        case .standard: return "Standard"
        case .strict: return "Strict"
        }
    }
}

public struct FaceMatch: Equatable, Sendable {
    public var templateID: UUID
    public var name: String
    /// Similarity to the template's averaged embedding.
    public var centroidSimilarity: Float
    /// Similarity to the closest single sample.
    public var bestSampleSimilarity: Float
}

public enum FaceMatcher {
    /// The best enabled template whose centroid **and** closest sample both clear `threshold`.
    ///
    /// Requiring both keeps an average of very different poses from matching loosely. There is
    /// deliberately no runner-up margin: the same person may be enrolled several times.
    public static func bestMatch(for embedding: [Float], in templates: [FaceTemplate], modelIdentifier: String,
                                 threshold: Float) -> FaceMatch? {
        let scored: [FaceMatch] = templates.compactMap { template in
            guard template.isEnabled, template.modelIdentifier == modelIdentifier,
                  let centroid = template.centroid else { return nil }
            let centroidSimilarity = FaceVector.cosineSimilarity(embedding, centroid)
            let best = template.samples.map { FaceVector.cosineSimilarity(embedding, $0) }.max() ?? centroidSimilarity
            return FaceMatch(templateID: template.id, name: template.name,
                             centroidSimilarity: centroidSimilarity, bestSampleSimilarity: best)
        }
        guard let top = scored.max(by: { $0.centroidSimilarity < $1.centroidSimilarity }),
              top.centroidSimilarity >= threshold, top.bestSampleSimilarity >= threshold else { return nil }
        return top
    }
}
