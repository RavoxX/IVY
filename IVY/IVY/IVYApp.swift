//
//  IVYApp.swift
//  IVY
//
//  IVY — a local AI assistant that lives in the MacBook notch.
//

import AppKit
import AppIntents
import Darwin

@main
enum IVYApp {
    @MainActor
    static func main() {
        #if DEBUG
        if CommandLine.arguments.dropFirst().first == "--ivy-verify-update" {
            let args = CommandLine.arguments
            guard args.count == 5 else { exit(2) }
            do {
                try UpdateInstaller.verify(URL(fileURLWithPath: args[2]), matching: URL(fileURLWithPath: args[3]), version: args[4])
                print("Update identity verified."); exit(0)
            } catch { print(error.localizedDescription); exit(1) }
        }
        #endif
        if UpdateInstaller.runIfRequested() { return }
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
