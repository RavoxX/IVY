import AppKit
import IVYCore

/// A click-through-to-the-button panel: it never takes focus from the selected field.
@MainActor
final class WritingSelectionIndicator: NSObject {
    private let panel = IndicatorPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var onClick: (() -> Void)?

    override init() {
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let button = IndicatorButton(frame: CGRect(origin: .zero, size: WritingIndicatorPlacement.size))
        button.isBordered = false; button.title = ""
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Open IVY writing assistant")
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.systemGreen.cgColor
        button.layer?.cornerRadius = 8
        button.target = self; button.action = #selector(clicked)
        button.toolTip = "Rewrite selected text with IVY"
        button.setAccessibilityLabel("Open IVY writing assistant")
        panel.contentView = button
    }

    func show(nextTo selection: CGRect, onClick: @escaping () -> Void) {
        guard let screen = NSScreen.screens.max(by: { intersectionArea($0.frame, selection) < intersectionArea($1.frame, selection) }),
              screen.frame.intersects(selection),
              let frame = WritingIndicatorPlacement.frame(selection: selection, visibleScreen: screen.visibleFrame) else { hide(); return }
        self.onClick = onClick
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil); onClick = nil }
    @objc private func clicked() {
        let action = onClick; hide(); action?()
    }
    private func intersectionArea(_ screen: CGRect, _ selection: CGRect) -> CGFloat {
        let rect = screen.intersection(selection)
        return rect.isNull ? 0 : rect.width * rect.height
    }
}

private final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class IndicatorButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
