import Foundation

/// Fast paths for files, clipboard, dictionary, mail, energy, Focus and Shortcuts.
extension CommandRouter {
    func routeFiles(_ text: String) -> ToolCall? {
        guard let request = FileSearchRequest.parse(text) else { return nil }
        var arguments: [String: JSONValue] = [:]
        if let name = request.name { arguments["name"] = .string(name) }
        if request.kind != .any { arguments["kind"] = .string(request.kind.rawValue) }
        if let modified = request.modified { arguments["modified"] = .string(modified.rawValue) }
        if let folder = request.folder { arguments["folder"] = .string(folder) }
        return ToolCall(name: ToolName.fileSearch, arguments: arguments)
    }

    func routeClipboard(_ text: String) -> ToolCall? {
        guard let intent = ClipboardTransforms.parseIntent(text) else { return nil }
        var arguments: [String: JSONValue] = ["action": .string(intent.action.rawValue)]
        if let detail = intent.detail { arguments["detail"] = .string(detail) }
        return ToolCall(name: ToolName.clipboard, arguments: arguments)
    }

    func routeDictionary(_ text: String) -> ToolCall? {
        guard let lookup = WordLookup.parse(text) else { return nil }
        return ToolCall(name: ToolName.dictionary, arguments: ["word": .string(lookup.word), "mode": .string(lookup.mode.rawValue)])
    }

    func routeMail(_ text: String) -> ToolCall? {
        guard let request = MailFilter.parse(text) else { return nil }
        var arguments: [String: JSONValue] = [:]
        if let from = request.from { arguments["from"] = .string(from) }
        if let query = request.query { arguments["query"] = .string(query) }
        if request.unreadOnly { arguments["unread_only"] = .bool(true) }
        return ToolCall(name: ToolName.mailSearch, arguments: arguments)
    }

    func routeEnergy(_ text: String) -> ToolCall? {
        EnergyAdvisor.matches(text) ? ToolCall(name: ToolName.energyStatus) : nil
    }

    func routeFocus(_ text: String) -> ToolCall? {
        if matches(text, #"^(what|which) focus( mode)? is (on|active|enabled)$"#)
            || matches(text, #"^(is|am i in) (a |any )?focus( mode)? (on|active)$"#)
            || matches(text, #"^what('s| is) my (current )?focus( mode)?$"#)
            || matches(text, #"^(is|am i in) do not disturb( on)?$"#) {
            return ToolCall(name: ToolName.focus, arguments: ["action": "status"])
        }
        let offPattern = #"^(?:turn off|switch off|disable|end|stop|leave|exit)(?: the)?(?: my)?(?: current)?(?: (\w+))? (focus|do not disturb)(?: mode)?$"#
        if let kind = capture(text, offPattern, group: 2) {
            var arguments: [String: JSONValue] = ["action": "off"]
            if kind == "do not disturb" {
                arguments["name"] = "Do Not Disturb"
            } else if let name = capture(text, offPattern, group: 1) {
                arguments["name"] = .string(name.capitalized)
            }
            return ToolCall(name: ToolName.focus, arguments: arguments)
        }
        // "create a shortcut that sets my focus to sleeping"
        if matches(text, #"^(create|make|set up|setup|add|build)\b.*\bshortcuts?\b"#), text.contains("focus") {
            let name = capture(text, #"\bfocus(?: mode)? (?:to|on|for) ([a-z]+(?: not disturb)?)"#)
                ?? capture(text, #"\b(?:my|the|a) ([a-z]+) focus\b"#)
            var arguments: [String: JSONValue] = ["action": "setup"]
            if let name { arguments["name"] = .string(name.capitalized) }
            return ToolCall(name: ToolName.focus, arguments: arguments)
        }
        if matches(text, #"^(turn on|switch on|enable|start|activate)( the)?( my)? do not disturb( mode)?$"#) {
            return ToolCall(name: ToolName.focus, arguments: ["action": "on", "name": "Do Not Disturb"])
        }
        if let name = capture(text, #"^(?:set|change|switch|put) (?:my |the )?focus(?: mode)? (?:to|on) ([a-z]+(?: [a-z]+)?)$"#)
            ?? capture(text, #"^(?:turn on|switch on|switch to|enable|start|activate)(?: the| my)? ([a-z]+(?: [a-z]+)?) focus(?: mode)?$"#) {
            return ToolCall(name: ToolName.focus, arguments: ["action": "on", "name": .string(name.capitalized)])
        }
        return nil
    }

    func routeLowPower(_ text: String) -> ToolCall? {
        let mode = #"(?:the )?(?:low power|low-power|energy saving|battery saver|power saving)(?: mode)?"#
        if matches(text, #"^(?:turn on|switch on|enable|activate|start|use) "# + mode + "$") {
            return ToolCall(name: ToolName.lowPowerMode, arguments: ["action": "on"])
        }
        if matches(text, #"^(?:turn off|switch off|disable|deactivate|stop) "# + mode + "$") {
            return ToolCall(name: ToolName.lowPowerMode, arguments: ["action": "off"])
        }
        if matches(text, #"^is "# + mode + #" (?:on|enabled|active)$"#) {
            return ToolCall(name: ToolName.lowPowerMode, arguments: ["action": "status"])
        }
        return nil
    }

    func routeShortcut(_ text: String) -> ToolCall? {
        guard let name = capture(text, #"^run (?:the |my )?shortcut (?:called |named )?(.+)$"#) else { return nil }
        return ToolCall(name: ToolName.shortcutRun, arguments: ["name": .string(name.trimmingCharacters(in: CharacterSet(charactersIn: "\"“” ")))])
    }
}
