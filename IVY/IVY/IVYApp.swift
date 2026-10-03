//
//  IVYApp.swift
//  IVY
//
//  IVY — a local AI assistant that lives in the MacBook notch.
//

import AppKit

@main
enum IVYApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Agent app: no Dock icon; UI lives in the notch and menu bar.
        app.setActivationPolicy(.accessory)
        ApplicationMenu.install()
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
