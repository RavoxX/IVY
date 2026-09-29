import os
import AVFoundation
import IVYCore

/// Captures microphone audio into memory as 16 kHz mono float samples (Whisper's format)
/// and reports a smoothed input level for the listening waveform.
///
/// The engine only runs while IVY is listening, so the macOS microphone indicator is
/// on exactly as long as audio is being captured.
final class AudioCaptureService: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noInput
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noInput: return "No microphone is available."
            case .permissionDenied: return "IVY needs microphone access. Enable it in System Settings → Privacy."
            }
        }
    }

    static let sampleRate: Double = 16_000
    /// Hard cap so a stuck key can't record forever (90 seconds).
    static let maxSamples = Int(sampleRate * 90)

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var running = false
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioCaptureService.sampleRate,
                                             channels: 1, interleaved: false)!

    /// Called on the audio thread with a 0…1 level.
    var onLevel: (@Sendable (Float) -> Void)?

    var isRunning: Bool { lock.withLock { running } }

    func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw CaptureError.permissionDenied }
        stopEngine()
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            samples.reserveCapacity(Int(Self.sampleRate * 10))
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.noInput }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        lock.withLock { running = true }
        Log.speech.debug("Microphone capture started")
    }

    /// Stops capture and hands back the recorded samples (the internal buffer is cleared).
    @discardableResult
    func stop() -> [Float] {
        stopEngine()
        return lock.withLock {
            let recorded = samples
            samples = []
            return recorded
        }
    }

    private func stopEngine() {
        let wasRunning = lock.withLock { () -> Bool in
            let value = running
            running = false
            return value
        }
        guard wasRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        Log.speech.debug("Microphone capture stopped")
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return }
        let count = Int(output.frameLength)
        guard count > 0 else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: count)

        var sum: Float = 0
        for value in chunk { sum += value * value }
        let rms = sqrt(sum / Float(count))

        lock.withLock {
            if samples.count < Self.maxSamples { samples.append(contentsOf: chunk) }
        }
        // Map roughly -50 dB…-10 dB to 0…1 for the waveform.
        let db = 20 * log10(max(rms, 1e-6))
        onLevel?(min(1, max(0, (db + 50) / 40)))
    }
}
