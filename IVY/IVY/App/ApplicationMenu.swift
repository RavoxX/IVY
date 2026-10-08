import AppKit

/// Accessory apps still need an Edit menu: AppKit routes command-key editing through
/// menu actions to the focused field editor, including SwiftUI SecureField controls.
/// The Window menu gives ⌘W/⌘M while IVY is a regular app (see `AppPresence`).
@MainActor
enum ApplicationMenu {
    static func install() {
        let main = NSMenu()
        let application = NSMenu(title: "IVY")
        application.addItem(withTitle: "IVY Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        application.addItem(.separator())
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

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = main.addItem(withTitle: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = window
        NSApplication.shared.mainMenu = main
        NSApplication.shared.windowsMenu = window
    }
}
