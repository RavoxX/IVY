import AVFoundation
import Combine
import IVYCore
import SwiftUI

/// Drives guided enrollment: camera frames → pose → `FaceEnrollmentProgress` → embeddings.
@MainActor
final class FaceEnrollmentSession: ObservableObject {
    enum Stage: Equatable { case starting, scanning, saving, done, failed(String) }

    @Published private(set) var stage: Stage = .starting
    @Published private(set) var progress = FaceEnrollmentProgress()
    @Published private(set) var faceVisible = false

    private let service: FaceUnlockService
    private let name: String
    private var task: Task<Void, Never>?
    private var samples: [[Float]] = []
    /// Nose offset while looking straight ahead; head turns are measured relative to it.
    private var baseline: [CGPoint] = []

    init(service: FaceUnlockService, name: String) {
        self.service = service
        self.name = name
    }

    var instruction: String {
        switch stage {
        case .starting: return "Starting camera…"
        case .saving: return "Saving…"
        case .done: return "Your face is set up."
        case .failed(let message): return message
        case .scanning:
            if !faceVisible { return "Position your face in the circle." }
            return progress.phase == .centering ? "Look straight at the camera." : "Move your head slowly to complete the circle."
        }
    }

    func start() {
        guard task == nil else { return }
        service.setEnrolling(true)
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        service.camera.stop()
        service.setEnrolling(false)
    }

    private func run() async {
        guard await FaceCamera.requestAccess() else {
            stage = .failed(FaceCameraError.denied.localizedDescription)
            return
        }
        let analyzer: FaceAnalyzer
        do {
            analyzer = try await service.loadAnalyzer()
            try await service.camera.start()
        } catch {
            stage = .failed(error.localizedDescription)
            return
        }
        stage = .scanning
        var lastFrame: UInt64 = 0
        while !Task.isCancelled, !progress.isComplete {
            guard let frame = service.camera.latestFrame(), frame.id != lastFrame else {
                try? await Task.sleep(for: .milliseconds(25))
                continue
            }
            lastFrame = frame.id
            let reading = await Task.detached(priority: .userInitiated) { analyzer.analyze(frame.image, minimumFaceWidth: 0.12) }.value
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { faceVisible = reading != nil }
            guard let reading else { continue }
            let (yaw, pitch) = pose(of: reading)
            var next = progress
            if let capture = next.observe(yaw: yaw, pitch: pitch, quality: reading.quality) {
                samples.append(reading.embedding)
                if capture == .center { baseline.append(reading.noseOffset) }
            }
            withAnimation(.easeOut(duration: 0.25)) { progress = next }
        }
        service.camera.stop()
        guard !Task.isCancelled else { return }
        stage = .saving
        do {
            try service.addTemplate(name: name, samples: samples)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { stage = .done }
        } catch {
            stage = .failed(error.localizedDescription)
        }
        service.setEnrolling(false)
    }

    /// Head pose in degrees as seen in the mirrored preview (positive: right / up).
    ///
    /// Before the straight-ahead baseline exists, Vision's own estimate decides "centered".
    /// Afterwards the nose's shift from that baseline is used, which reliably tells left
    /// from right regardless of the camera's yaw sign convention.
    private func pose(of reading: FaceReading) -> (Double, Double) {
        guard progress.phase != .centering, !baseline.isEmpty else {
            let degrees = 180 / Double.pi
            return ((reading.yaw ?? 0) * degrees, (reading.pitch ?? 0) * degrees)
        }
        let reference = CGPoint(x: baseline.map(\.x).reduce(0, +) / CGFloat(baseline.count),
                                y: baseline.map(\.y).reduce(0, +) / CGFloat(baseline.count))
        // The nose sits roughly half an eye distance in front of the eyes.
        func degrees(_ shift: CGFloat) -> Double { asin(max(-1, min(1, Double(shift) / 0.5))) * 180 / .pi }
        // Unmirrored image: turning right moves the nose toward image-left; looking up moves it up.
        return (degrees(reference.x - reading.noseOffset.x), degrees(reference.y - reading.noseOffset.y))
    }
}

/// Face ID setup sheet: a mirrored, circular camera preview inside a ring of ticks that
/// fill as you move your head, like setting up Face ID on iPhone.
struct FaceEnrollmentView: View {
    @StateObject private var session: FaceEnrollmentSession
    @ObservedObject private var service: FaceUnlockService
    let onClose: () -> Void
    @State private var password = ""
    @State private var passwordError: String?
    @State private var savingPassword = false

    init(service: FaceUnlockService, name: String, onClose: @escaping () -> Void) {
        _session = StateObject(wrappedValue: FaceEnrollmentSession(service: service, name: name))
        self.service = service
        self.onClose = onClose
    }

    private let diameter: CGFloat = 230

    var body: some View {
        VStack(spacing: 22) {
            Text("How to Set Up Face ID").font(.title3.bold())
            ZStack {
                if session.stage == .done {
                    Circle().fill(Color.green.opacity(0.12))
                    SuccessGlyph().transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    CameraPreview(session: session.stage == .scanning ? sessionCamera : nil)
                        .clipShape(Circle())
                        .overlay(Circle().fill(.black.opacity(session.faceVisible ? 0 : 0.35)))
                        .transition(.opacity)
                }
                EnrollmentRing(progress: session.progress, complete: session.stage == .done)
                    .frame(width: diameter + 46, height: diameter + 46)
            }
            .frame(width: diameter, height: diameter)
            .padding(23)

            Text(session.instruction)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(height: 36)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: session.instruction)

            if needsPassword {
                // Face ID can't unlock without it, so finish setup here instead of leaving
                // the step for a section further down in Settings.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last step: your Mac login password").font(.headline)
                    SecureField("Login password for \(NSUserName())", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(savePassword)
                    Text(passwordError ?? "IVY checks it against your account, then stores it encrypted to type it on the lock screen.")
                        .font(.caption)
                        .foregroundStyle(passwordError == nil ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack {
                if needsPassword {
                    Button("Later") { close() }.keyboardShortcut(.cancelAction)
                        .help("Face ID can't unlock your Mac until the password is saved")
                    Button(savingPassword ? "Checking…" : "Save and Finish", action: savePassword)
                        .keyboardShortcut(.defaultAction)
                        .disabled(password.isEmpty || savingPassword)
                } else if session.stage == .done {
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(28)
        .frame(width: 400)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: needsPassword)
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }

    private var sessionCamera: AVCaptureSession { service.camera.session }

    private var needsPassword: Bool { session.stage == .done && !service.hasPassword }

    private func savePassword() {
        guard !password.isEmpty, !savingPassword else { return }
        savingPassword = true
        let candidate = password
        Task {
            let error = await service.savePassword(candidate)
            savingPassword = false
            passwordError = error
            if error == nil {
                password = ""
                close()
            }
        }
    }

    private func close() {
        session.stop()
        onClose()
    }
}

/// Plays the Face ID success morph once when enrollment finishes.
private struct SuccessGlyph: View {
    @State private var done = false

    var body: some View {
        FaceIDGlyph(state: done ? .success : .idle, size: 90, color: .green)
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { done = true } }
    }
}

/// 60 ticks around the preview. Lit ticks turn green and grow, like iPhone's Face ID setup.
private struct EnrollmentRing: View {
    let progress: FaceEnrollmentProgress
    let complete: Bool

    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) / 2
            ZStack {
                ForEach(0..<FaceEnrollmentProgress.tickCount, id: \.self) { index in
                    let lit = complete || progress.litTicks.contains(index)
                    // Tick 0 points right; indices run counter-clockwise (y up), matching the progress model.
                    let angle = -Double(index) / Double(FaceEnrollmentProgress.tickCount) * 360
                    Capsule()
                        .fill(lit ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: lit ? 16 : 11, height: 3)
                        .offset(x: radius - (lit ? 8 : 5.5))
                        .rotationEffect(.degrees(angle))
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: lit)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// Mirrored live camera preview (nil session shows black).
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession?

    func makeNSView(context: Context) -> PreviewView { PreviewView() }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.previewLayer.session = session
        if let connection = view.previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            previewLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
