@preconcurrency import AVFoundation
import CoreImage
import IVYCore
import os

/// One downscaled camera frame. Frames live only in memory and are never written to disk.
struct FaceFrame: @unchecked Sendable {
    let id: UInt64
    let image: CGImage
}

enum FaceCameraError: LocalizedError {
    case denied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .denied: return "IVY needs camera access for Face ID. Allow it in System Settings ▸ Privacy & Security ▸ Camera."
        case .unavailable: return "No camera is available."
        }
    }
}

/// Owns the capture session for Face ID and keeps only the newest frame.
///
/// The camera (and its green indicator light) runs only during enrollment or a scan.
final class FaceCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Exposed so the enrollment view can attach a preview layer to the same session.
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.ravoxx.IVY.faceid.camera")
    private let context = CIContext()
    private let lock = NSLock()
    private var latest: FaceFrame?
    private var nextID: UInt64 = 0
    private var isConfigured = false
    /// Vision works well and fast at this size.
    private let maxLongEdge: CGFloat = 640

    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Starts capturing. Never prompts while the screen is locked: callers ask for access in Settings.
    func start() async throws {
        guard Self.isAuthorized else { throw FaceCameraError.denied }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try configureIfNeeded()
                    if !session.isRunning { session.startRunning() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            lock.withLock { latest = nil }
        }
    }

    func latestFrame() -> FaceFrame? {
        lock.withLock { latest }
    }

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }
        let device = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                      mediaType: .video, position: .unspecified)
            .devices.sorted { lhs, _ in lhs.deviceType == .builtInWideAngleCamera }.first
            ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { throw FaceCameraError.unavailable }
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        isConfigured = true
        Log.faceID.info("Camera configured: \(device.localizedName, privacy: .public)")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var image = CIImage(cvPixelBuffer: buffer)
        let longEdge = max(image.extent.width, image.extent.height)
        if longEdge > maxLongEdge {
            let scale = maxLongEdge / longEdge
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        nextID &+= 1
        let frame = FaceFrame(id: nextID, image: cgImage)
        lock.withLock { latest = frame }
    }
}
