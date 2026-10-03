import AppKit
import Combine
import IVYCore
import SwiftUI

@MainActor
final class BenchmarkViewModel: ObservableObject {
    @Published private(set) var results: [BenchmarkResult] = []
    @Published private(set) var running = false
    @Published private(set) var usage: [AIUsage] = []
    private var runner: AssistantBenchmark?
    private var task: Task<Void, Never>?
    func run(env: AppEnvironment) {
        guard !running, !env.notch.isBusy else { return }
        results = []; usage = []; running = true
        let model = env.languageModel.forRequest()
        let runner = AssistantBenchmark(llm: model, options: env.settings.generationOptions)
        self.runner = runner
        task = Task { [self] in
            let start = Date()
            await runner.run { [weak self] result in await MainActor.run { [weak self] in self?.results.append(result) } }
            usage = await env.usage.all().filter { $0.date >= start }
            running = false
        }
    }
    func stop() { task?.cancel(); Task { await runner?.cancel(); running = false } }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "IVY-benchmark.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        struct Report: Codable { let date: Date; let results: [BenchmarkResult]; let usage: [AIUsage] }
        do { try JSONEncoder().encode(Report(date: Date(), results: results, usage: usage)).write(to: url, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }
}

struct BenchmarkSettings: View {
    let env: AppEnvironment
    @AppStorage(SettingsKey.aiProvider.rawValue) private var activeProvider = AIProvider.local.rawValue
    @AppStorage(SettingsKey.taskModels.rawValue) private var taskModels = "{}"
    @StateObject private var model = BenchmarkViewModel()
    var body: some View {
        Form {
            Section("Daily workflow benchmark") {
                Text("12 scenarios cover English and German requests, ambiguous meetings, corrections, event follow-ups, failed tools, chains, and web answers. The selected model uses synthetic tools: this changes no real accounts, files, reminders, or calendars.")
                    .font(.callout)
                Text("Cloud runs make billable API requests; stop at any time. Results are a small diagnostic sample, not a guarantee of accuracy. Compare repeated runs before choosing a model.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Run with \(commandProvider.displayName)") { model.run(env: env) }.disabled(model.running || env.notch.isBusy)
                    if model.running { Button("Stop") { model.stop() }; ProgressView().controlSize(.small) }
                    if !model.results.isEmpty { Button("Export report") { model.export() } }
                }
            }
            if !model.results.isEmpty {
                Section("Results") {
                    LabeledContent("Passed scenarios", value: "\(model.results.filter(\.passed).count) / \(model.results.count)")
                    LabeledContent("Wrong actions", value: "\(model.results.map(\.wrongActions).reduce(0, +))")
                    LabeledContent("Total time", value: String(format: "%.1f s", model.results.map(\.seconds).reduce(0, +)))
                    LabeledContent("Model requests", value: "\(model.usage.count)")
                    LabeledContent("Input / output tokens", value: "\(model.usage.compactMap(\.inputTokens).reduce(0, +)) / \(model.usage.compactMap(\.outputTokens).reduce(0, +))")
                    ForEach(model.results) { result in
                        HStack {
                            Image(systemName: result.passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(result.passed ? .green : .orange)
                            VStack(alignment: .leading) { Text(result.id).bold(); Text(result.detail).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Text(String(format: "%.1f s", result.seconds)).font(.caption.monospacedDigit())
                        }
                    }
                }
            }
        }.formStyle(.grouped)
    }

    private var commandProvider: AIProvider {
        _ = activeProvider; _ = taskModels
        return env.settings.modelChoice(for: .commands).provider
    }
}
