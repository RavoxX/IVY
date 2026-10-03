import AppKit
import IVYCore
import SwiftUI
import UniformTypeIdentifiers

struct DashboardSettings: View {
    let env: AppEnvironment
    @AppStorage(SettingsKey.dashboardWidgets.rawValue) private var widgets = "reminders,event,mail,focus,battery"
    @AppStorage(SettingsKey.dashboardMusic.rawValue) private var music = true
    @AppStorage(SettingsKey.dashboardBatteryHeader.rawValue) private var battery = true
    @AppStorage(SettingsKey.showGlance.rawValue) private var glance = true
    private var order: [DashboardWidget] {
        let selected = env.settings.dashboardWidgets
        return selected + DashboardWidget.allCases.filter { !selected.contains($0) }
    }
    var body: some View {
        Form {
            Section("Dashboard layout") {
                Toggle("Show music player", isOn: $music)
                Toggle("Show battery in the dashboard header", isOn: $battery)
                Toggle("Show status widgets", isOn: $glance)
                Text("Choose the lines shown on Home and change their order. Hidden sources aren't read for the dashboard. The Ask IVY button always stays available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Status widgets") {
                ForEach(order) { widget in
                    HStack {
                        Toggle(isOn: Binding(get: { env.settings.dashboardWidgets.contains(widget) }, set: { enabled in
                            var selected = env.settings.dashboardWidgets
                            selected.removeAll { $0 == widget }
                            if enabled { selected.append(widget) }
                            widgets = selected.map(\.rawValue).joined(separator: ",")
                        })) { Label(widget.title, systemImage: widget.symbol) }
                        Button { move(widget, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(env.settings.dashboardWidgets.first == widget || !env.settings.dashboardWidgets.contains(widget)).help("Move up")
                        Button { move(widget, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(env.settings.dashboardWidgets.last == widget || !env.settings.dashboardWidgets.contains(widget)).help("Move down")
                    }
                }
            }
            Section {
                Button("Restore dashboard defaults") {
                    widgets = "reminders,event,mail,focus,battery"; music = true; battery = true; glance = true
                }
                Text("Calendar and reminder widgets use granted permissions. Unread email uses Apple Mail when it is running; connected MCP apps are available to the assistant.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .onChange(of: widgets) { _, _ in env.glance.refresh(force: true) }
        .onChange(of: glance) { _, _ in env.glance.refresh(force: true) }
    }
    private func move(_ widget: DashboardWidget, by amount: Int) {
        var values = env.settings.dashboardWidgets
        guard let index = values.firstIndex(of: widget), values.indices.contains(index + amount) else { return }
        values.swapAt(index, index + amount); widgets = values.map(\.rawValue).joined(separator: ",")
    }
}

struct UsageSettings: View {
    let store: UsageStore
    @State private var records: [AIUsage] = []
    @State private var days = 30
    @State private var clear = false
    @State private var provider = "all"
    private var filtered: [AIUsage] {
        records.filter { $0.date >= Date().addingTimeInterval(-Double(days) * 86400) && (provider == "all" || $0.provider.rawValue == provider) }
    }
    var body: some View {
        Form {
            Section("Usage inside IVY") {
                HStack {
                    Picker("Period", selection: $days) { Text("24 hours").tag(1); Text("7 days").tag(7); Text("30 days").tag(30); Text("365 days").tag(365) }
                    Picker("Provider", selection: $provider) {
                        Text("All providers").tag("all")
                        ForEach(AIProvider.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    Button("Refresh") { Task { records = await store.all() } }
                }
                HStack(spacing: 28) {
                    metric("Requests", "\(filtered.count)")
                    metric("Input tokens", "\(filtered.compactMap(\.inputTokens).reduce(0, +))")
                    metric("Output tokens", "\(filtered.compactMap(\.outputTokens).reduce(0, +))")
                    metric("Failures", "\(filtered.filter { !$0.succeeded }.count)")
                }.padding(.vertical, 10)
                LabeledContent("Cached input tokens", value: "\(filtered.compactMap(\.cachedTokens).reduce(0, +))")
                LabeledContent("Average response time", value: filtered.isEmpty ? "—" : String(format: "%.1f s", filtered.map(\.seconds).reduce(0, +) / Double(filtered.count)))
                Text("Counts come from provider responses or the local engine. Unknown token counts are omitted, not estimated. This records IVY activity only; it doesn't show your account balance, quotas, or charges from other apps. Local warm-up requests are included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Provider billing & limits") {
                Link("OpenAI usage", destination: URL(string: "https://platform.openai.com/usage")!)
                Link("Anthropic billing", destination: URL(string: "https://platform.claude.com/settings/billing")!)
                Link("Google AI Studio usage", destination: URL(string: "https://aistudio.google.com/usage")!)
            }
            Section("Recent requests") {
                if filtered.isEmpty { Text("No measured requests in this period.").foregroundStyle(.secondary) }
                ForEach(filtered.prefix(50)) { record in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(record.model).font(.callout)
                            Text(record.provider.displayName + " · " + record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(record.inputTokens.map(String.init) ?? "—") in · \(record.outputTokens.map(String.init) ?? "—") out").font(.caption.monospacedDigit())
                        Image(systemName: record.succeeded ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(record.succeeded ? .green : .orange)
                    }
                }
            }
            Section {
                Button("Export usage JSON") { export() }
                Button("Clear usage records…", role: .destructive) { clear = true }
                Text("Usage records contain counts, model IDs and timing only. No prompts, responses or credentials are stored here.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).task { records = await store.all() }
        .confirmationDialog("Clear usage records?", isPresented: $clear) {
            Button("Clear", role: .destructive) { Task { await store.clear(); records = [] } }
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) { Text(value).font(.title2.bold().monospacedDigit()); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "IVY-usage.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONEncoder().encode(filtered).write(to: url, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }
}

struct UpdateSettings: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Form {
            Section("IVY updates") {
                LabeledContent("Installed version", value: updater.currentVersion)
                Text(updater.message).textSelection(.enabled)
                HStack {
                    Button("Check for updates") { updater.check() }.disabled(updater.busy)
                    if let update = updater.available {
                        Button("Update to \(update.version) & restart") { updater.update() }.disabled(updater.busy)
                    }
                    if updater.busy { Button("Cancel") { updater.cancel() }; ProgressView().controlSize(.small) }
                }
                if let progress = updater.progress { ProgressView(value: progress).progressViewStyle(.linear) }
                Text("Updates download the latest stable DMG from IVY's GitHub repository, verify its SHA-256 digest and the app's signing team, then replace this copy and restart. Checks and downloads run only when you click these buttons.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Download manually / all releases", destination: AppUpdater.releasesURL)
            }
            if let update = updater.available {
                Section("What's new in \(update.version)") { Text(update.notes).textSelection(.enabled); Link("View release", destination: update.releaseURL) }
            }
        }.formStyle(.grouped)
    }
}

struct HistorySettings: View {
    let env: AppEnvironment
    @ObservedObject var model: NotchViewModel
    @State private var search = ""
    @State private var selected: HistoryEntry?
    @State private var clear = false
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                TextField("Search requests and answers", text: $search).textFieldStyle(.roundedBorder)
                Button("Refresh") { Task { await model.reloadHistory() } }
                Button("Clear…", role: .destructive) { clear = true }
            }
            List(model.history.filter { search.isEmpty || ($0.query + " " + $0.result).localizedCaseInsensitiveContains(search) }) { entry in
                Button { selected = entry } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(entry.title).font(.headline); Spacer(); Text(entry.timestamp.formatted()).font(.caption).foregroundStyle(.secondary) }
                        Text(entry.query).lineLimit(2)
                        Text(entry.result).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if entry.status != .success { Text(entry.status.rawValue.capitalized).font(.caption).foregroundStyle(.orange) }
                    }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }.padding(24).task { await model.reloadHistory() }
        .sheet(item: $selected) { entry in
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(entry.title).font(.title2.bold()); Spacer(); Button("Done") { selected = nil } }
                ScrollView { VStack(alignment: .leading, spacing: 16) { Text(entry.query).bold(); Text(entry.result).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading) }
                Text("Running a request again can repeat its actions.").font(.caption).foregroundStyle(.secondary)
                Button("Use request in Assistant") { env.workspaceDraft = entry.query; selected = nil; env.openSettings(section: "assistant") }
            }.padding(24).frame(width: 660, height: 560)
        }
        .confirmationDialog("Clear local request history?", isPresented: $clear) {
            Button("Clear", role: .destructive) { model.clearHistory() }
        }
    }
}

struct RoutineSettings: View {
    let env: AppEnvironment
    @State private var routines: [AssistantRoutine] = []
    @State private var name = ""
    @State private var commands = ""
    @State private var editingID: UUID?
    @State private var error = ""
    var body: some View {
        Form {
            Section("Saved routines") {
                Text("Run up to eight assistant requests in order. A failure or question stops the routine. Tools use the same validation and confirmation rules as normal requests. Routines run only when you click Run.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(routines) { routine in
                    HStack {
                        VStack(alignment: .leading) { Text(routine.name).bold(); Text("\(routine.commands.count) steps").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Edit") { editingID = routine.id; name = routine.name; commands = routine.commands.joined(separator: "\n") }
                        Button("Run") { env.openSettings(section: "assistant"); env.notch.runRoutine(routine) }.disabled(env.notch.isBusy)
                        Button("Delete", role: .destructive) {
                            Task { do { try await env.routines.remove(routine.id); routines = await env.routines.all() } catch { self.error = error.localizedDescription } }
                        }
                    }
                }
            }
            Section(editingID == nil ? "Create routine" : "Edit routine") {
                TextField("Name", text: $name)
                Text("One request per line, in execution order.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $commands).frame(minHeight: 100).font(.body)
                HStack {
                    Button("Save routine") {
                        Task {
                            do {
                                let routine = AssistantRoutine(id: editingID ?? UUID(), name: name,
                                    commands: commands.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                                try await env.routines.save(routine); routines = await env.routines.all(); name = ""; commands = ""; editingID = nil; error = ""
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(name.isEmpty || commands.isEmpty)
                    if editingID != nil { Button("Cancel edit") { editingID = nil; name = ""; commands = "" } }
                }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }.formStyle(.grouped).task { routines = await env.routines.all() }
    }
}
