import AppKit
import ApplicationServices
import Combine
import IVYCore
import SwiftUI

struct FaceIDSettings: View {
    let env: AppEnvironment
    @ObservedObject var service: FaceUnlockService
    @AppStorage(SettingsKey.faceUnlockEnabled.rawValue) private var enabled = false
    @AppStorage(SettingsKey.faceUnlockOnWake.rawValue) private var onWake = true
    @AppStorage(SettingsKey.faceUnlockOnLock.rawValue) private var onLock = false
    @AppStorage(SettingsKey.faceUnlockStrictness.rawValue) private var strictness = FaceMatchStrictness.standard.rawValue
    @AppStorage(SettingsKey.faceUnlockLiveness.rawValue) private var liveness = true
    @AppStorage(SettingsKey.faceUnlockScanSeconds.rawValue) private var scanSeconds = 6.0

    @State private var cameraGranted = FaceCamera.isAuthorized
    @State private var accessibilityGranted = PasswordTyper.isTrusted
    @State private var confirmEnable = false
    @State private var confirmReset = false
    @State private var enrollingName: String?
    @State private var password = ""
    @State private var passwordMessage: String?
    @State private var savingPassword = false

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                SecurityNotice()
            }

            Section("Face ID") {
                Toggle("Unlock this Mac with Face ID", isOn: Binding(get: { enabled }, set: { newValue in
                    if newValue { confirmEnable = true } else { enabled = false; service.cancelScan() }
                }))
                HStack(spacing: 12) {
                    FaceIDGlyph(state: readyGlyph, size: 26, color: service.missingRequirement == nil ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.missingRequirement == nil ? "Ready" : "Not ready yet").font(.callout.weight(.medium))
                        Text(service.missingRequirement ?? "IVY looks for your face when the screen locks or wakes, then types your password.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !service.status.isEmpty {
                    Text(service.status).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Set up") {
                requirementRow("Camera", granted: cameraGranted, detail: "Frames are analyzed in memory and never saved.") {
                    Button("Allow Camera") {
                        Task {
                            _ = await FaceCamera.requestAccess()
                            cameraGranted = FaceCamera.isAuthorized
                            if !cameraGranted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                requirementRow("Accessibility", granted: accessibilityGranted, detail: "Lets IVY type your password on the lock screen.") {
                    Button("Allow Accessibility") {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                        env.permissions.open(.accessibility)
                    }
                }
                requirementRow("Face ID data", granted: service.isVaultUnlocked,
                               detail: "Encrypted with a Secure Enclave key. Unlock once with Touch ID after IVY starts.") {
                    Button(service.hasData ? "Unlock with Touch ID" : "Create with Touch ID") {
                        Task { await service.unlockVault() }
                    }
                }
            }

            if service.isVaultUnlocked {
                Section {
                    if service.hasPassword {
                        HStack {
                            Label("Password saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Spacer()
                            Button("Remove", role: .destructive) { service.removePassword() }
                        }
                    }
                    HStack {
                        SecureField(service.hasPassword ? "Replace password" : "Mac login password", text: $password)
                            .onSubmit(savePassword)
                        Button(savingPassword ? "Checking…" : "Save", action: savePassword)
                            .disabled(password.isEmpty || savingPassword)
                    }
                    if let passwordMessage {
                        Text(passwordMessage).font(.caption).foregroundStyle(.red)
                    }
                    Text("IVY checks the password against your account before saving it. Update it here whenever you change your login password.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    HStack(spacing: 6) {
                        Text("Login password")
                        if !service.hasPassword {
                            Text("Required")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(.orange))
                        }
                    }
                }

                Section("Faces") {
                    ForEach(service.templates) { template in
                        HStack {
                            Image(systemName: "faceid").foregroundStyle(.secondary)
                            Text(template.name)
                            Text("\(template.samples.count) views").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Toggle("Use", isOn: Binding(get: { template.isEnabled },
                                                        set: { service.setTemplate(template.id, enabled: $0) }))
                                .labelsHidden()
                            Button(role: .destructive) { service.removeTemplate(template.id) } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless).help("Remove this face")
                        }
                    }
                    Button(service.templates.isEmpty ? "Set Up Face ID…" : "Set Up an Alternate Appearance…") {
                        enrollingName = service.templates.isEmpty ? "Me" : "Alternate appearance \(service.templates.count)"
                    }
                    Text("Only face embeddings (numbers) are stored, never images. Add an alternate appearance for glasses or different lighting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Behavior") {
                Toggle("Look for my face when the Mac wakes", isOn: $onWake)
                Toggle("Also look right after the screen locks", isOn: $onLock)
                Picker("Match", selection: $strictness) {
                    ForEach(FaceMatchStrictness.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented)
                Toggle("Require a blink or head turn (liveness check)", isOn: $liveness)
                if !liveness {
                    Text("Without the liveness check, a photo of you can unlock this Mac.")
                        .font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("Scan for") {
                    HStack {
                        Slider(value: $scanSeconds, in: 3...10, step: 1).frame(width: 160)
                        Text("\(Int(scanSeconds)) s").monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                }
                Text("Hover the notch on the lock screen to try again. Typing your password always works.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Try it") {
                HStack {
                    Button("Test Face ID in the Notch") { service.startScan(.test) }
                        .disabled(!service.isVaultUnlocked || service.templates.isEmpty || !cameraGranted || service.isScanning)
                    Spacer()
                    Button("Delete Face ID Data…", role: .destructive) { confirmReset = true }
                        .disabled(!service.hasData && !service.isVaultUnlocked)
                }
                Text("The test only recognizes you; it never types your password.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in
            cameraGranted = FaceCamera.isAuthorized
            accessibilityGranted = PasswordTyper.isTrusted
        }
        .confirmationDialog("Turn on Face ID for unlocking?", isPresented: $confirmEnable) {
            Button("I Understand, Turn On") {
                enabled = true
                if !service.isVaultUnlocked { Task { await service.unlockVault() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("IVY's Face ID is a convenience feature and is not as secure as Apple's Face ID or Touch ID. A video of you or someone who looks like you may unlock your Mac, and IVY stores your login password to type it for you.")
        }
        .confirmationDialog("Delete all Face ID data?", isPresented: $confirmReset) {
            Button("Delete", role: .destructive) { service.resetAll() }
        } message: {
            Text("Removes your enrolled faces, the stored password and the keys, and turns Face ID off.")
        }
        .sheet(item: Binding(get: { enrollingName.map(EnrollmentRequest.init) }, set: { enrollingName = $0?.name })) { request in
            FaceEnrollmentView(service: service, name: request.name) { enrollingName = nil }
        }
    }

    private var readyGlyph: FaceIDGlyph.Phase {
        service.missingRequirement == nil ? .success : .idle
    }

    private func savePassword() {
        guard !password.isEmpty, !savingPassword else { return }
        savingPassword = true
        let candidate = password
        Task {
            passwordMessage = await service.savePassword(candidate)
            if passwordMessage == nil { password = "" }
            savingPassword = false
        }
    }

    @ViewBuilder
    private func requirementRow(_ title: String, granted: Bool, detail: String, @ViewBuilder action: () -> some View) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { action() }
        }
    }
}

private struct EnrollmentRequest: Identifiable {
    let name: String
    var id: String { name }
}

/// The required disclaimer: IVY's Face ID trades security for convenience.
private struct SecurityNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Not as secure as Apple's Face ID or Touch ID").font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    bullet("Your Mac's camera sees a flat 2D image. It has no depth sensor like iPhone's Face ID.")
                    bullet("The liveness check stops printed photos and still images, but a video of you, or someone who looks very similar, may unlock your Mac.")
                    bullet("macOS doesn't let apps approve a login, so IVY stores your login password (encrypted with a Secure Enclave key) and types it on the lock screen.")
                    bullet("Use it as a convenience only. Don't turn it on for Macs that hold sensitive data or that others can reach unattended.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
