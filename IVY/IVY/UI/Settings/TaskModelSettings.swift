import IVYCore
import SwiftUI

struct TaskModelSettings: View {
    let env: AppEnvironment
    @AppStorage(SettingsKey.taskModels.rawValue) private var storedChoices = "{}"
    var body: some View {
        Section("Models by task · \(env.settings.routingMode)") {
            Text("Choose a provider and model for each task, or inherit the main provider. Cloud tasks send their input and needed context to that provider; Local tasks run on this Mac. All cloud choices use the API key saved for that provider.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(AITask.allCases) { task in
                TaskModelRow(task: task, settings: env.settings, choices: $storedChoices)
            }
        }
    }
}
private struct TaskModelRow: View {
    let task: AITask
    let settings: SettingsStore
    @Binding var choices: String
    private var selected: TaskModelChoice? { settings.taskModelChoices[task.rawValue] }
    private var provider: Binding<String> {
        Binding(get: { selected?.provider.rawValue ?? "inherit" }, set: { value in
            if let provider = AIProvider(rawValue: value) {
                settings.setTaskModel(.init(provider: provider, model: provider == .local ? settings.string(.llmModelID) : settings.cloudModel(for: provider)), for: task)
            } else { settings.setTaskModel(nil, for: task) }
            choices = settings.string(.taskModels)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(task.title, selection: provider) {
                Text("Inherit main / writing provider").tag("inherit")
                ForEach(AIProvider.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            if let selected {
                if selected.provider == .local {
                    Picker("Local model", selection: modelBinding) {
                        ForEach(ModelCatalog.llms) { Text($0.displayName).tag($0.id) }
                    }
                    Text("The selected local model must be installed.").font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Model ID", text: modelBinding)
                    Text("Uses your \(selected.provider.displayName) key. Test this ID in that provider's configuration below.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 6)
    }
    private var modelBinding: Binding<String> {
        Binding(get: { selected?.model ?? "" }, set: { value in
            guard var choice = selected else { return }; choice.model = value
            settings.setTaskModel(choice, for: task); choices = settings.string(.taskModels)
        })
    }
}
