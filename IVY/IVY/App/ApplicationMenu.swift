import AppKit

/// Accessory apps still need an Edit menu: AppKit routes command-key editing through
/// menu actions to the focused field editor, including SwiftUI SecureField controls.
@MainActor
enum ApplicationMenu {
    static func install() {
        let main = NSMenu()
        let application = NSMenu(title: "IVY")
        application.addItem(withTitle: "Quit IVY", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let applicationItem = main.addItem(withTitle: "IVY", action: nil, keyEquivalent: "")
        applicationItem.submenu = application

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        NSApplication.shared.mainMenu = main
    }
}
