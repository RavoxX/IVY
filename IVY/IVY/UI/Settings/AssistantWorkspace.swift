import AppKit
import IVYCore
import SwiftUI
import UniformTypeIdentifiers

/// The full window uses the same agent and confirmations as the notch.
struct AssistantWorkspace: View {
    let env: AppEnvironment
    @ObservedObject var model: NotchViewModel
    @AppStorage(SettingsKey.aiProvider.rawValue) private var providerID = AIProvider.local.rawValue
    @AppStorage(SettingsKey.taskModels.rawValue) private var taskModels = "{}"
    @State private var prompt = ""
    @State private var attachments: [ContextAttachment] = []
    @State private var error = ""
    @State private var adding = false
    @State private var contextPreview = false
    @AppStorage(SettingsKey.assistantPreferences.rawValue) private var preferences = ""
    @AppStorage(SettingsKey.conversationMinutes.rawValue) private var minutes = 30

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                let choice = model.activeModelChoice
                Label(choice.provider.displayName, systemImage: choice.provider == .local ? "desktopcomputer" : "cloud")
                Text(choice.model)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if env.undo.latestLabel != nil {
                    Button("Undo latest action") { model.submit("Undo my last action") }.disabled(model.isBusy)
                        .help(env.undo.latestLabel ?? "Undo")
                }
                Button("New conversation") { model.newConversation(); attachments = []; prompt = "" }.disabled(model.isBusy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.query.isEmpty && model.answer.isEmpty {
                        ContentUnavailableView("Ask IVY anything", systemImage: "sparkles", description: Text("Ask about your Mac, connected apps, or attach context below."))
                    }
                    if !model.query.isEmpty { Text(model.query).font(.headline).textSelection(.enabled) }
                    if !model.steps.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.steps) { step in
                                HStack(alignment: .top) {
                                    Image(systemName: step.status == "Success" ? "checkmark.circle.fill" : step.status == "Failure" ? "exclamationmark.circle.fill" : "circle.dotted")
                                        .foregroundStyle(step.status == "Failure" ? .orange : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(step.name + " · " + step.status).font(.callout.bold())
                                        if !step.detail.isEmpty { Text(step.detail).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if model.isBusy && model.confirmation == nil { HStack { ProgressView().controlSize(.small); Text(model.workingLabel ?? "Thinking…").foregroundStyle(.secondary) } }
                    if let request = model.confirmation {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Confirm action · \(request.displayName)", systemImage: "hand.raised").font(.headline)
                            Text(request.prompt).textSelection(.enabled)
                            HStack {
                                Button("Allow") { model.resolveConfirmation(true) }
                                Button("Cancel", role: .cancel) { model.resolveConfirmation(false) }
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if !model.answer.isEmpty { Text(.init(model.answer)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    if case .error(let message) = model.phase { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
                    ForEach(Array(model.cards.enumerated()), id: \.offset) { _, card in
                        ResultCardView(card: card, model: model).padding().background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if model.steps.contains(where: { $0.status == "Failure" }) && !model.isBusy {
                        Button("Retry failed actions only") { model.retryFailedActions() }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
            if !attachments.isEmpty {
                HStack {
                    Label("\(attachments.count) context items", systemImage: "paperclip")
                    Button("Preview what will be sent") { contextPreview = true }
                    Spacer()
                    Button("Remove all") { attachments = [] }
                }.font(.caption)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading) }
            HStack(alignment: .bottom) {
                TextField("Message IVY", text: $prompt, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...5)
                    .onSubmit(send).disabled(model.isBusy)
                if model.isBusy { Button("Stop") { model.dismiss() } }
                else { Button("Send", action: send).keyboardShortcut(.return, modifiers: .command).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            HStack {
                Menu {
                    Button("Attach document or image…") { chooseFiles() }
                    Button("Add selected text") {
                        do { attachments.append(try ContextAttachmentService.selectedText(application: env.selectionApplication)); error = "" }
                        catch { self.error = error.localizedDescription }
                    }
                    Button("Add copied text") {
                        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                            attachments.append(ContextAttachment(name: "Copied text", text: String(text.prefix(12_000))))
                        } else { error = "The clipboard contains no text." }
                    }
                    Button("Take screenshot…") { screenshot() }
                } label: { Label("Add context", systemImage: "plus") }
                .disabled(adding || model.isBusy || attachments.count >= 4)
                if adding { ProgressView().controlSize(.small) }
                Text(env.settings.aiProvider == .local ? "Context stays on this Mac." : "Send includes this context in a \(env.settings.aiProvider.displayName) API request.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("History") { env.openSettings(section: "history") }
            }
            DisclosureGroup("Personal preferences") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tell IVY your preferred language, tone, or formatting. These preferences are editable and are sent to the model with your requests.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $preferences).frame(height: 65)
                    Stepper("Remember this conversation for \(minutes) minutes", value: $minutes, in: 1...120)
                        .onChange(of: minutes) { _, value in Task { await env.agent.setConversationLifetime(minutes: value) } }
                }.padding(.top, 8)
            }
        }.padding(24)
        .onAppear {
            model.workspaceVisible = true
            if !env.workspaceDraft.isEmpty { prompt = env.workspaceDraft; env.workspaceDraft = "" }
            let urls = env.workspaceAttachments; env.workspaceAttachments = []
            if !urls.isEmpty { addFiles(urls) }
        }
        .onDisappear { model.workspaceVisible = false }
        .sheet(isPresented: $contextPreview) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Context preview").font(.title2.bold()); Spacer(); Button("Done") { contextPreview = false } }
                Text("Only this extracted text is sent when you press Send. Document extraction is capped at 30 PDF pages and 12,000 characters per item; images use local text recognition.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    ForEach(attachments) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(item.name).bold(); Spacer(); Button("Remove") { attachments.removeAll { $0.id == item.id } } }
                            Text(item.text).font(.callout).textSelection(.enabled)
                            Divider()
                        }
                    }
                }
            }.padding(24).frame(width: 700, height: 600)
        }
    }
    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.isBusy else { return }
        let context = attachments.isEmpty ? nil : attachments.map { "Attachment: \($0.name)\n\($0.text)" }.joined(separator: "\n\n")
        prompt = ""; error = ""
        model.submit(text, context: context)
    }
    private func chooseFiles() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .text, .image, .json]
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }
    private func addFiles(_ urls: [URL]) {
        guard !adding else { return }
        adding = true
        Task {
            for url in urls.prefix(max(0, 4 - attachments.count)) {
                do {
                    let attachment = try await Task.detached(priority: .userInitiated) { try ContextAttachmentService.read(url) }.value
                    attachments.append(attachment)
                } catch { self.error = error.localizedDescription }
            }
            adding = false
            contextPreview = !attachments.isEmpty
        }
    }
    private func screenshot() {
        guard !adding else { return }
        let url = AppPaths.temporary.appendingPathComponent("context-\(UUID().uuidString).png")
        try? FileManager.default.createDirectory(at: AppPaths.temporary, withIntermediateDirectories: true)
        adding = true
        Task {
            let code = await Task.detached { UpdateInstaller.process("/usr/sbin/screencapture", ["-i", url.path]) }.value
            defer { try? FileManager.default.removeItem(at: url); adding = false }
            if code == 0, FileManager.default.fileExists(atPath: url.path) {
                do {
                    attachments.append(try await Task.detached { try ContextAttachmentService.read(url) }.value)
                    contextPreview = true
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
