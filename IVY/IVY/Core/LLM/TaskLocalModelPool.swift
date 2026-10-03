import Foundation
import IVYCore

/// Per-task local models have separate sidecars. They share the existing idle/energy limits.
final class TaskLocalModelPool: @unchecked Sendable {
    private let lock = NSLock()
    private var models: [String: MLXLLMService] = [:]
    private let settings: SettingsStore
    private let governor: EnergyGovernor
    private let usage: UsageStore
    init(settings: SettingsStore, governor: EnergyGovernor, usage: UsageStore) {
        self.settings = settings; self.governor = governor; self.usage = usage
    }
    func model(_ id: String) -> MLXLLMService {
        lock.withLock {
            if let model = models[id] { return model }
            let model = MLXLLMService(settings: settings, governor: governor, modelOverride: id, usage: { [usage] in await usage.append($0) })
            models[id] = model
            return model
        }
    }
    func unload() async {
        let values = lock.withLock { Array(models.values) }
        for model in values { await model.unloadModel() }
    }
    func applyIdleTimeout() async {
        let values = lock.withLock { Array(models.values) }
        for model in values { await model.applyIdleTimeout() }
    }
}
