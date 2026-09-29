import AppKit
import IVYCore

/// Optional menu bar item: Open IVY, IVY Settings…, Pause IVY, Quit IVY.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let env: AppEnvironment
    private let showSetup: () -> Void

    init(env: AppEnvironment, showSetup: @escaping () -> Void) {
        self.env = env
        self.showSetup = showSetup
        super.init()
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "IVY")
            image?.isTemplate = true
            item.button?.image = image
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let paused = env.settings.bool(.paused)
        menu.addItem(withTitle: "Open IVY", action: #selector(openIVY), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Dashboard", action: #selector(openDashboard), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "IVY Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Setup…", action: #selector(openSetup), keyEquivalent: "").target = self
        let pause = menu.addItem(withTitle: paused ? "Resume IVY" : "Pause IVY", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit IVY", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func openIVY() { env.notch.enterTextMode() }
    @objc private func openDashboard() { env.notch.openDashboard() }
    @objc private func openSettings() { env.openSettings() }
    @objc private func openSetup() { showSetup() }
    @objc private func togglePause() {
        let paused = !env.settings.bool(.paused)
        env.settings.set(paused, for: .paused)
        if paused { env.notch.dismiss() }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
