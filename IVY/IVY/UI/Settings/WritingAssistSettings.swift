import IVYCore
import SwiftUI

struct WritingAssistSettings: View {
    let env: AppEnvironment
    @AppStorage(SettingsKey.writingAssistEnabled.rawValue) private var enabled = true
    @AppStorage(SettingsKey.writingAssistOnSelection.rawValue) private var automatic = true
    @AppStorage(SettingsKey.writingLanguage.rawValue) private var language = "English"

    var body: some View {
        Form {
            Section("Write with IVY") {
                Toggle("Enable writing assistant", isOn: $enabled)
                Toggle("Offer rewriting when I select text in an editable field", isOn: $automatic).disabled(!enabled)
                Text("Only editable text fields are eligible. Read-only text, webpage articles and password fields are excluded. IVY previews Improve, Rephrase, Shorten, tone changes and Translate in the notch; Accept replaces the selection only if the field and selection still match.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Select text you are editing, then press ⌃⌥W or choose Writing Assistant from the IVY menu. Accessibility permission is required.")
                    .font(.callout)
                Button("Accessibility settings") { env.permissions.open(.accessibility) }
            }
            Section("Translation") {
                TextField("Target language", text: $language)
            }
            Section("Models & privacy") {
                Text("Grammar & rewriting and Translation have separate provider and model choices in AI settings. Selecting text alone makes no AI request. Cloud processing starts when you choose a writing action.")
                    .font(.callout)
                Button("Choose models by task") { env.openSettings(section: "ai") }
            }
        }.formStyle(.grouped)
    }
}
