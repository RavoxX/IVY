import Foundation

/// Builds the small one-action `.shortcut` workflows IVY offers to install for things macOS
/// only lets Shortcuts do (switching a Focus).
/// The file is signed by macOS (`shortcuts sign`) and imported only after the user clicks
/// "Add Shortcut" in the Shortcuts app.
public enum ShortcutBuilder {
    /// Apple's identifiers for the standard Focus modes. The user's own list (read from the
    /// Focus database with Full Disk Access) takes precedence and covers custom modes.
    public static let standardFocusIdentifiers: [String: String] = [
        "Do Not Disturb": "com.apple.donotdisturb.mode.default",
        "Sleep": "com.apple.sleep.sleep-mode",
        "Work": "com.apple.focus.work",
        "Personal": "com.apple.focus.personal-time",
        "Driving": "com.apple.donotdisturb.mode.driving",
        "Fitness": "com.apple.donotdisturb.mode.workout",
        "Gaming": "com.apple.focus.gaming",
        "Mindfulness": "com.apple.focus.mindfulness",
        "Reading": "com.apple.focus.reading",
        "Reduce Interruptions": "com.apple.focus.reduce-interruptions",
    ]

    /// Shortcut names IVY looks for and creates: "Sleep Focus", "Sleep Focus Off", "Focus Off".
    public static func focusShortcutName(focus: String?, on: Bool) -> String {
        let base = focus.map { "\($0) Focus" } ?? "Focus"
        return on ? base : "\(base) Off"
    }

    /// Set Focus (on/off). Without a mode, "off" ends whichever Focus is on.
    public static func focusWorkflow(focus: String?, identifier: String?, on: Bool) throws -> Data {
        var parameters: [String: Any] = ["Enabled": on ? 1 : 0]
        if let focus, let identifier {
            parameters["FocusModes"] = ["DisplayString": focus, "Identifier": identifier]
        }
        return try workflow(action: "is.workflow.actions.dnd.set", parameters: parameters)
    }

    static func workflow(action: String, parameters: [String: Any]) throws -> Data {
        let workflow: [String: Any] = [
            "WFWorkflowActions": [[
                "WFWorkflowActionIdentifier": action,
                "WFWorkflowActionParameters": parameters,
            ]],
            "WFWorkflowClientVersion": "2607.0.2",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 463_140_863, "WFWorkflowIconGlyphNumber": 59_511],
            "WFWorkflowImportQuestions": [Any](),
            "WFWorkflowInputContentItemClasses": [Any](),
            "WFWorkflowOutputContentItemClasses": [Any](),
            "WFWorkflowTypes": [Any](),
            "WFQuickActionSurfaces": [Any](),
            "WFWorkflowHasOutputFallback": false,
        ]
        return try PropertyListSerialization.data(fromPropertyList: workflow, format: .binary, options: 0)
    }

    /// File names can't contain "/" or ":"; custom Focus names may contain emoji, which is fine.
    public static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: #"[/:\\\u0000-\u001F]"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(60))
    }
}
