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
                Toggle("Show a green button beside selected editable text", isOn: $automatic).disabled(!enabled)
                Text("Only editable text fields are eligible. Read-only text, webpage articles and password fields are excluded. IVY previews Improve, Rephrase, Shorten, tone changes and Translate in the notch; Accept replaces the selection only if the field and selection still match.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Finish selecting text you are editing. A slim, muted green button appears after you release the mouse or finish keyboard selection. Click it to open the notch. Selection alone never opens the writing assistant. You can also press ⌃⌥W or choose Writing Assistant from the IVY menu. Accessibility permission is required. In Microsoft Word, invoke Writing Assistant manually once to allow Automation; the selection button then appears in the document body.")
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
