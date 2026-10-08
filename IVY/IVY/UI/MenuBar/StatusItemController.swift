import AppKit
import IVYCore

/// Optional menu bar item: Open IVY, IVY Settings…, Pause IVY, Quit IVY.
///
/// The menu is built once with SF Symbols (the macOS 26 menu style); opening it only
/// refreshes the status header and the Pause item instead of rebuilding every item.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let env: AppEnvironment
    private let showSetup: () -> Void
    private let statusHeader = NSMenuItem()
    private var pauseItem: NSMenuItem?

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
            item.menu = makeMenu()
            self.item = item
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        statusHeader.isEnabled = false
        menu.addItem(statusHeader)
        menu.addItem(.separator())

        menu.addItem(entry("Ask IVY", symbol: "sparkles", action: #selector(openIVY)))
        menu.addItem(entry("Assistant Window", symbol: "macwindow", action: #selector(openAssistantWindow)))
        menu.addItem(entry("Writing Assistant", symbol: "pencil.line", action: #selector(openWritingAssistant),
                           key: "w", modifiers: [.control, .option]))
        menu.addItem(entry("Show Dashboard", symbol: "rectangle.topthird.inset.filled", action: #selector(openDashboard)))
        menu.addItem(.separator())

        menu.addItem(entry("Settings…", symbol: "gearshape", action: #selector(openSettings), key: ","))
        menu.addItem(entry("Setup…", symbol: "wand.and.stars", action: #selector(openSetup)))
        let pause = entry("Pause IVY", symbol: "pause.circle", action: #selector(togglePause))
        pauseItem = pause
        menu.addItem(pause)
        menu.addItem(.separator())

        menu.addItem(entry("Quit IVY", symbol: "power", action: #selector(quit), key: "q"))
        return menu
    }

    private func entry(_ title: String, symbol: String, action: Selector, key: String = "",
                       modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        let paused = env.settings.bool(.paused)
        let title = NSMutableAttributedString(string: "IVY", attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
        title.append(NSAttributedString(string: paused ? "  Paused" : "  Ready",
                                        attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
        statusHeader.attributedTitle = title
        statusHeader.image = NSImage(systemSymbolName: paused ? "pause.circle.fill" : "leaf.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [paused ? .systemOrange : .systemGreen]))
        pauseItem?.title = paused ? "Resume IVY" : "Pause IVY"
        pauseItem?.image = NSImage(systemSymbolName: paused ? "play.circle" : "pause.circle", accessibilityDescription: nil)
    }

    @objc private func openIVY() { env.notch.enterTextMode() }
    @objc private func openAssistantWindow() { env.openSettings(section: "assistant") }
    @objc private func openWritingAssistant() { env.writingAssist.prepare() }
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

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
