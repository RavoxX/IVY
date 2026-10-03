import AppKit
import IVYCore
import Security
import SwiftUI

struct CloudProviderSettings: View {
    let provider: AIProvider
    var usage: UsageStore? = nil
    @State private var discovered: [String] = []
    @State private var testing = false
    @State private var model = ""
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var message = ""
    @State private var failed = false

    private var preset: Binding<String> {
        Binding(get: { (provider.suggestedModels + discovered).contains(model) ? model : "custom" }, set: {
            model = $0 == "custom" ? "" : $0
        })
    }

    var body: some View {
        Section(provider.displayName) {
            Picker("Model", selection: preset) {
                ForEach(Array(Set(provider.suggestedModels + discovered)).sorted(), id: \.self) { Text($0).tag($0) }
                Text("Custom model ID").tag("custom")
            }
            TextField("Model ID", text: $model)
                .onChange(of: model) { _, value in
                    if let setting = provider.modelSetting { SettingsStore().set(value, for: setting) }
                }
            if CloudModelConfiguration(provider: provider, model: model, apiKey: "configured").validationError != nil {
                Text(CloudModelError.invalidModel.localizedDescription).font(.caption).foregroundStyle(.red)
            }
            Text("Choose a text model with function calling that your API account can access. You can enter another model ID above.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                SecureField(keySaved ? "Replace API key" : "API key", text: $apiKey)
                    .onSubmit { saveKey() }
                Button("Paste") {
                    if let value = NSPasteboard.general.string(forType: .string) { apiKey = value }
                }
                .help("Paste your API key from the clipboard")
            }
            HStack {
                Button("Save API Key", action: saveKey)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if keySaved {
                    Label("Key saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Remove Key", role: .destructive) { updateKey("") }
                }
                Spacer()
                Link("Get an API key", destination: provider.apiKeyURL)
            }
            HStack {
                Button("Test connection") { testConnection() }.disabled(testing || !keySaved)
                Button("Refresh model list") { refreshModels() }.disabled(testing || !keySaved)
                if testing { ProgressView().controlSize(.small) }
            }
            Text("Testing sends a small billable request to the selected model. Refresh retrieves model IDs from this API account; some listed models may not support text or tools.").font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(failed ? .red : .secondary)
            }
            Text("Your key is stored in macOS Keychain, separately for each provider. Selecting a provider or opening IVY sends no test requests. Cloud requests start only when a model is needed for your command.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            model = SettingsStore().cloudModel(for: provider)
            keySaved = !(Keychain.read(account: provider.keychainAccount) ?? "").isEmpty
        }
    }

    private func testConnection() {
        testing = true; message = "Testing model access…"; failed = false
        let configuration = CloudModelConfiguration(provider: provider, model: model, apiKey: Keychain.read(account: provider.keychainAccount) ?? "")
        Task {
            defer { testing = false }
            do {
                let service = CloudLLMService(configuration: configuration, usage: { [usage] in await usage?.append($0) })
                _ = try await service.generateResponse(messages: [.user("Reply with OK.")], tools: [], options: .init(maxTokens: 2048)) { _ in }
                message = "Connected. This account can generate text with \(configuration.model)."
            } catch { failed = true; message = error.localizedDescription }
        }
    }
    private func refreshModels() {
        testing = true; failed = false; message = "Loading model IDs…"
        Task {
            defer { testing = false }
            do {
                discovered = try await CloudModelDiscovery.models(provider: provider, apiKey: Keychain.read(account: provider.keychainAccount) ?? "")
                message = "Loaded \(discovered.count) model IDs from your account."
            } catch { failed = true; message = error.localizedDescription }
        }
    }

    private func saveKey() {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isNewline }) else {
            failed = true
            message = "Enter a valid API key without line breaks."
            return
        }
        updateKey(value)
    }

    private func updateKey(_ value: String) {
        let status = Keychain.write(value, account: provider.keychainAccount)
        failed = status != errSecSuccess
        if failed {
            message = "Keychain couldn't save this change (\(status)). No key change was saved."
        } else {
            keySaved = !value.isEmpty
            apiKey = ""
            message = keySaved ? "API key saved." : "API key removed."
        }
    }
}
