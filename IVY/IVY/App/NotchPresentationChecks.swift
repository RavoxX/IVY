#if DEBUG
import AppKit
import Darwin
import IVYCore

/// Runs against the real view model and NSPanel. No shortcuts, microphone or models
/// are started, and AppDelegate supplies isolated settings for this check.
@MainActor
enum NotchPresentationChecks {
    static func run(env: AppEnvironment, controller: NotchWindowController) async {
        let model = env.notch!
        func settle() async { try? await Task.sleep(for: .milliseconds(250)) }
        func check(_ condition: Bool, _ label: String) {
            guard condition else {
                FileHandle.standardError.write(Data("FAIL: \(label)\n".utf8))
                exit(1)
            }
            print("PASS: \(label)")
        }

        env.openSettings(section: "general")
        await settle()
        check(!model.workspaceVisible && controller.panel.isVisible, "General settings leave the notch available")

        model.moveToWorkspace()
        await settle()
        check(!controller.panel.isVisible, "Expanding a task hides the notch")

        model.presentVoiceActivationPreview()
        await settle()
        check(!model.workspaceVisible && model.phase == .listening && controller.panel.isVisible,
              "Voice activation returns from the window to a visible notch")

        model.moveToWorkspace()
        model.presentDemo(query: "Example", answer: "Example answer", cards: [], phase: .answered)
        await settle()
        check(!controller.panel.isVisible, "A workspace answer stays in the window")
        model.enterTextMode()
        await settle()
        check(!model.workspaceVisible && model.phase == .textInput && controller.panel.isVisible && controller.panel.isKeyWindow,
              "Text activation returns an existing conversation to the notch and takes focus")

        model.dismiss()
        await settle()
        check(model.mode == .closed && !model.workspaceVisible && controller.panel.isVisible,
              "Dismissal leaves the notch available for hover")
        model.moveToWorkspace()
        model.openDashboard()
        await settle()
        check(model.mode == .dashboard && !model.workspaceVisible && controller.panel.isVisible,
              "Opening the hover dashboard clears a stale window destination")
        model.dismiss()
        model.moveToWorkspace()
        model.enterTextMode()
        await settle()
        check(model.mode == .assistant && !model.workspaceVisible && controller.panel.isVisible,
              "Text activation from the closed state restores the notch")

        env.settings.reset(keepSetupState: false)
        exit(0)
    }
}
#endif
