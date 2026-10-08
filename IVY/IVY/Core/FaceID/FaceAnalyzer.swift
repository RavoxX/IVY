import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import IVYCore
import Vision

/// Everything IVY needs from one camera frame: an identity embedding plus the pose and
/// landmark measurements used by enrollment and the liveness check.
struct FaceReading: Sendable {
    let embedding: [Float]
    /// Vision's normalized box (bottom-left origin).
    let boundingBox: CGRect
    let quality: Float?
    /// Vision's head pose estimate, in radians.
    let yaw: Double?
    let pitch: Double?
    /// Mean eye height/width; drops during a blink.
    let eyeOpenness: Double?
    /// Nose position relative to the eye midpoint, divided by the eye distance, in
    /// unmirrored image space (x right, y down). Shifts with head turns because the nose
    /// sticks out of the face.
    let noseOffset: CGPoint
}

enum FaceAnalyzerError: LocalizedError {
    case modelMissing
    case modelFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "The Face ID model is missing from IVY's app bundle."
        case .modelFailed(let detail): return "The Face ID model couldn't run: \(detail)"
        }
    }
}

/// Vision face detection + 5-point alignment + ArcFace embedding, all on-device.
///
/// Pipeline adapted from Glance (MIT, github.com/jonnyoo/glance). Thread-safe for one caller
/// at a time; run it off the main actor because Core ML prediction blocks.
final class FaceAnalyzer: @unchecked Sendable {
    /// Stored with every template so embeddings from another model are never compared.
    static let modelIdentifier = "arcface-w600k_mbf-v1"
    private static let inputName = "input_image"
    private static let outputName = "embedding"

    private let model: MLModel
    private let pool: CVPixelBufferPool

    init() throws {
        guard let url = Bundle.main.url(forResource: "ArcFace", withExtension: "mlmodelc") else { throw FaceAnalyzerError.modelMissing }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        do {
            model = try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            throw FaceAnalyzerError.modelFailed(error.localizedDescription)
        }
        let size = FaceAlignment.outputSize
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        guard let pool else { throw FaceAnalyzerError.modelFailed("pixel buffer pool") }
        self.pool = pool
    }

    /// Analyzes the most prominent face, ignoring faces narrower than `minimumFaceWidth`
    /// (fraction of the frame) so bystanders in the background are never considered.
    func analyze(_ image: CGImage, minimumFaceWidth: CGFloat = 0.16) -> FaceReading? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let rectangles = VNDetectFaceRectanglesRequest()
        guard (try? handler.perform([rectangles])) != nil,
              let face = rectangles.results?
                .filter({ $0.boundingBox.width >= minimumFaceWidth })
                .max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
        else { return nil }

        let landmarksRequest = VNDetectFaceLandmarksRequest()
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        landmarksRequest.inputFaceObservations = [face]
        qualityRequest.inputFaceObservations = [face]
        try? handler.perform([landmarksRequest, qualityRequest])
        guard let landmarks = landmarksRequest.results?.first?.landmarks else { return nil }

        let size = CGSize(width: image.width, height: image.height)
        guard let points = Self.keyPoints(landmarks, imageSize: size),
              let aligned = Self.align(image, points: points.alignment),
              let embedding = try? embed(aligned) else { return nil }

        return FaceReading(embedding: embedding,
                           boundingBox: face.boundingBox,
                           quality: qualityRequest.results?.first?.faceCaptureQuality,
                           yaw: face.yaw?.doubleValue,
                           pitch: face.pitch?.doubleValue,
                           eyeOpenness: points.eyeOpenness,
                           noseOffset: points.noseOffset)
    }

    // MARK: - Landmarks

    private struct KeyPoints {
        var alignment: [CGPoint]
        var eyeOpenness: Double?
        var noseOffset: CGPoint
    }

    /// Image-space points (top-left origin) in ArcFace order: left eye, right eye, nose,
    /// left and right mouth corner. Left/right are as seen in the image.
    private static func keyPoints(_ landmarks: VNFaceLandmarks2D, imageSize: CGSize) -> KeyPoints? {
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            region?.pointsInImage(imageSize: imageSize).map { CGPoint(x: $0.x, y: imageSize.height - $0.y) } ?? []
        }
        func center(_ points: [CGPoint]) -> CGPoint? {
            guard !points.isEmpty else { return nil }
            return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                           y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        }
        func aspect(_ points: [CGPoint]) -> Double? {
            guard points.count >= 3, let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX > minX else { return nil }
            return Double((maxY - minY) / (maxX - minX))
        }

        let leftEyePoints = points(landmarks.leftEye), rightEyePoints = points(landmarks.rightEye)
        guard let eyeA = center(points(landmarks.leftPupil)) ?? center(leftEyePoints),
              let eyeB = center(points(landmarks.rightPupil)) ?? center(rightEyePoints),
              let nose = center(points(landmarks.nose)) else { return nil }
        let lips = points(landmarks.outerLips)
        guard let mouthLeft = lips.min(by: { $0.x < $1.x }), let mouthRight = lips.max(by: { $0.x < $1.x }) else { return nil }

        // Vision's left/right eye labels are anatomical; ArcFace wants image order.
        let (imageLeft, imageRight) = eyeA.x <= eyeB.x ? (eyeA, eyeB) : (eyeB, eyeA)
        let distance = hypot(imageRight.x - imageLeft.x, imageRight.y - imageLeft.y)
        guard distance > 1 else { return nil }
        let middle = CGPoint(x: (imageLeft.x + imageRight.x) / 2, y: (imageLeft.y + imageRight.y) / 2)

        let openness = [aspect(leftEyePoints), aspect(rightEyePoints)].compactMap { $0 }
        return KeyPoints(alignment: [imageLeft, imageRight, nose, mouthLeft, mouthRight],
                         eyeOpenness: openness.isEmpty ? nil : openness.reduce(0, +) / Double(openness.count),
                         noseOffset: CGPoint(x: (nose.x - middle.x) / distance, y: (nose.y - middle.y) / distance))
    }

    /// Warps the face onto ArcFace's canonical 112×112 template.
    private static func align(_ image: CGImage, points: [CGPoint]) -> CGImage? {
        let height = CGFloat(image.height), output = CGFloat(FaceAlignment.outputSize)
        // CGContext is y-up, so solve in flipped coordinates on both sides.
        let source = points.map { CGPoint(x: $0.x, y: height - $0.y) }
        let destination = FaceAlignment.referencePoints.map { CGPoint(x: $0.x, y: output - $0.y) }
        guard let transform = FaceAlignment.similarityTransform(from: source, to: destination),
              let context = CGContext(data: nil, width: FaceAlignment.outputSize, height: FaceAlignment.outputSize,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    // MARK: - Embedding

    private func embed(_ face: CGImage) throws -> [Float] {
        var bufferOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &bufferOut)
        guard let buffer = bufferOut else { throw FaceAnalyzerError.modelFailed("pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(face, in: CGRect(x: 0, y: 0, width: face.width, height: face.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard context != nil else { throw FaceAnalyzerError.modelFailed("drawing context") }

        let input = try MLDictionaryFeatureProvider(dictionary: [Self.inputName: MLFeatureValue(pixelBuffer: buffer)])
        guard let array = try model.prediction(from: input).featureValue(for: Self.outputName)?.multiArrayValue,
              array.count == 512 else { throw FaceAnalyzerError.modelFailed("unexpected output") }
        // MLMultiArray storage isn't guaranteed to be contiguous; index through the array.
        return FaceVector.normalized((0..<array.count).map { array[$0].floatValue })
    }
}
