#if DEBUG
import AVFoundation
import Foundation
import IVYCore
import os

/// Debug-build-only automation hook used for end-to-end testing without a keyboard:
///
///     swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(
///         .init("com.ravoxx.IVY.debug"), object: "submit", userInfo: ["text": "Open Safari"],
///         deliverImmediately: true)'
///
/// Commands: submit(text), text, dashboard(tab), dismiss, audio(path) — the latter runs a
/// recorded file through the same Whisper → agent path as the microphone.
/// Not compiled into Release builds.
@MainActor
enum DebugBridge {
    private static var observer: NSObjectProtocol?

    static func install(env: AppEnvironment) {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.ravoxx.IVY.debug"), object: nil, queue: .main
        ) { notification in
            let command = notification.object as? String ?? ""
            let info = notification.userInfo ?? [:]
            MainActor.assumeIsolated { handle(command, info: info, env: env) }
        }
        Log.ui.info("Debug bridge installed")
    }

    private static func handle(_ command: String, info: [AnyHashable: Any], env: AppEnvironment) {
        let notch = env.notch!
        switch command {
        case "submit":
            if let text = info["text"] as? String { notch.submit(text) }
        case "text":
            notch.enterTextMode()
        case "dashboard":
            notch.openDashboard(tab: (info["tab"] as? String).flatMap(DashboardTab.init(rawValue:)))
        case "dismiss":
            notch.dismiss()
        case "settings":
            env.openSettings(section: info["section"] as? String)
        case "audio":
            guard let path = info["path"] as? String, let samples = loadSamples(path) else { return }
            Task {
                let text = (try? await env.whisper.transcribe(samples: samples, sampleRate: 16_000)) ?? ""
                Log.ui.info("Debug transcription: \(text, privacy: .public)")
                notch.submit(text)
            }
        default:
            Log.ui.error("Unknown debug command \(command, privacy: .public)")
        }
    }

    /// Reads any audio file and converts it to 16 kHz mono float samples.
    private static func loadSamples(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil else { return nil }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        converter.convert(to: output, error: nil) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
#endif
