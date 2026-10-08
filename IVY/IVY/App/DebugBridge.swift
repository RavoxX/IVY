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
/// recorded file through the same Whisper → agent path as the microphone — and
/// faceid(state: armed|scanning|blink|success|failure|hide) to preview the Face ID overlay.
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
            if let pid = info["pid"] as? String, pid != String(ProcessInfo.processInfo.processIdentifier) { return }
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
            notch.isPinnedForDemo = false
            notch.dismiss()
        case "demo":
            presentDemo(info["scene"] as? String ?? "", env: env)
        case "settings":
            env.openSettings(section: info["section"] as? String)
        case "faceid":
            previewFaceID(info["state"] as? String ?? "scanning", overlay: env.faceUnlock.overlay)
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

    /// Sample scenes for README screenshots (no personal data).
    private static func presentDemo(_ scene: String, env: AppEnvironment) {
        let notch = env.notch!
        let today = Calendar.current.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int = 0) -> Date { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: today)! }
        let billieJean = MusicState(status: .playing, title: "Billie Jean", artist: "Michael Jackson", album: "Thriller",
                                    artworkURL: URL(string: "https://i.scdn.co/image/ab67616d0000b2734121faee8df82c526cbab2be"),
                                    trackID: "spotify:track:5ChkMS8OtdzJeqyybCc9R5", duration: 294, position: 62, volume: 70)
        switch scene {
        case "reminders":
            notch.presentDemo(query: "What's on my to-do list for today?", answer: "You have three reminders due today.",
                              cards: [.reminders(title: "Today's Reminders", items: [
                                  ReminderItem(id: "1", title: "Get homework done", dueDate: at(0), hasDueTime: false),
                                  ReminderItem(id: "2", title: "Meeting with the design team", dueDate: at(19), hasDueTime: true),
                                  ReminderItem(id: "3", title: "Call Alex about the trip", dueDate: at(20, 30), hasDueTime: true),
                              ])], phase: .answered)
        case "music":
            env.music.update(billieJean)
            notch.presentDemo(query: "Play Billie Jean.", answer: "Playing Billie Jean by Michael Jackson.",
                              cards: [.music(billieJean)], phase: .answered)
        case "listening":
            notch.presentDemo(query: "", answer: "", cards: [], phase: .listening, audioLevel: 0.75)
        case "typing":
            notch.enterTextMode()
            // Type after the field has focus so the text isn't shown selected.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { notch.typedText = "What's the weather tomorrow?" }
        case "claude":
            let info = CodingSessionInfo(agent: "Claude Code", projectName: "personal-website",
                                         directory: URL(fileURLWithPath: NSHomeDirectory() + "/IVY Projects/personal-website"),
                                         task: "Build a personal website", mode: .background, status: .running)
            notch.presentDemo(query: "Open Claude Code and start building a personal website.",
                              answer: "Claude Code is building your personal website in the background. I'll show it here when it's done.",
                              cards: [.codingSession(info)], phase: .answered)
        case "dashboard":
            env.music.update(billieJean)
            notch.dismiss()
            notch.openDashboard(tab: .home)
            notch.isPinnedForDemo = true
            // Stop live Spotify polling so the sample track stays on screen.
            env.music.endLiveUpdates()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { env.music.update(billieJean) }
        case "shelf":
            notch.dismiss()
            notch.openDashboard(tab: .shelf)
            notch.isPinnedForDemo = true
        case "live":
            env.music.update(billieJean)
            notch.dismiss()
        default:
            break
        }
    }

    /// Drives the Face ID overlay without a camera, for checking its animations.
    private static func previewFaceID(_ state: String, overlay: FaceUnlockOverlay) {
        switch state {
        case "armed": overlay.arm()
        case "scanning": overlay.beginScan()
        case "blink": overlay.beginScan(); overlay.setHint(.blink)
        case "success": overlay.finish(success: true, thenArm: false)
        case "failure": overlay.finish(success: false, thenArm: false)
        default: overlay.hide()
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
