import AppKit
import IVYCore
import SwiftUI

/// Compact first-run setup: explains local processing, requests permissions, detects
/// integrations and installs the runtime + models on explicit request.
struct SetupView: View {
    let env: AppEnvironment
    @ObservedObject var runtime: RuntimeManager
    @ObservedObject var permissions: PermissionService
    @ObservedObject var claude: ClaudeCodeService
    let finish: () -> Void

    private var requiredModels: [ModelDescriptor] {
        [ModelCatalog.defaultLLM, ModelCatalog.defaultWhisper, ModelCatalog.kokoro]
    }

    private var totalDownload: Int64 {
        requiredModels.filter { !runtime.isInstalled($0) }.reduce(0) { $0 + $1.approximateBytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                IVYMark(active: false).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to IVY").font(.title2.bold())
                    Text("A private assistant that lives in your notch. Everything runs locally on your Mac.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    step(1, "Permissions") {
                        permissionLine("Microphone — to hear your questions", permissions.microphone) {
                            Task { _ = await permissions.requestMicrophone() }
                        }
                        permissionLine("Reminders — for your to-do list (optional)", permissions.reminders) {
                            Task { await permissions.requestReminders(using: env.reminders) }
                        }
                        permissionLine("Input Monitoring — best shortcut detection (optional)", permissions.inputMonitoring) {
                            permissions.requestInputMonitoring()
                            permissions.open(.inputMonitoring)
                        }
                    }
                    step(2, "Integrations") {
                        detectLine("Spotify", detected: env.spotify.isInstalled, detail: env.spotify.isInstalled ? "Installed" : "Not installed")
                        detectLine("Claude Code", detected: claude.detected[.claude] != nil,
                                   detail: claude.detected[.claude].map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Not found")
                    }
                    step(3, "Local AI runtime") {
                        RuntimeSection(runtime: runtime)
                            .labelsHidden()
                    }
                    step(4, "Models") {
                        ForEach(requiredModels) { model in
                            ModelRow(model: model, runtime: runtime)
                        }
                        Text("Download needed: \(ByteCountFormatter.string(fromByteCount: totalDownload, countStyle: .file)) · Free disk space: \(ByteCountFormatter.string(fromByteCount: runtime.freeDiskBytes, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                        if RuntimeManager.isRuntimeInstalled, totalDownload > 0 {
                            Button("Download All") { requiredModels.filter { !runtime.isInstalled($0) }.forEach(runtime.download) }
                        }
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Text("Hold ⌘ ⌥ to talk · hold, release ⌘, press ⌘ to type")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Finish Setup", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .onAppear {
            permissions.refresh()
            runtime.refresh()
            Task { await claude.refreshDetection() }
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(number). \(title)").font(.headline)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
    }

    private func permissionLine(_ title: String, _ status: PermissionService.Status, request: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(status == .granted ? .green : .secondary)
            Text(title)
            Spacer()
            if status == .notDetermined {
                Button("Allow", action: request)
            } else if status == .denied {
                Button("Open Settings…") { permissions.open(.microphone) }
            }
        }
    }

    private func detectLine(_ title: String, detected: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: detected ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(detected ? .green : .secondary)
            Text(title)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

@MainActor
final class SetupWindowController {
    private var window: NSWindow?
    private let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    func show() {
        if window == nil {
            let view = SetupView(env: env, runtime: env.runtime, permissions: env.permissions, claude: env.claudeCode) { [weak self] in
                self?.complete()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Set Up IVY"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func complete() {
        env.settings.set(true, for: .hasCompletedSetup)
        window?.close()
    }
}
