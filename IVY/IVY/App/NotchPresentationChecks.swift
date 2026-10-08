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

        await checkShelfDrop(env: env, controller: controller, settle: settle, check: check)

        env.settings.reset(keepSetupState: false)
        exit(0)
    }

    /// Feeds a real file-URL drag into the panel's AppKit drop target.
    private static func checkShelfDrop(env: AppEnvironment, controller: NotchWindowController, settle: () async -> Void,
                                       check: (Bool, String) -> Void) async {
        let model = env.notch!
        model.dismiss()
        model.openDashboard(tab: .home)
        await settle()
        guard let container = controller.panel.contentView else { return check(false, "Panel has a content view") }
        check(container.registeredDraggedTypes.contains(.fileURL), "The notch panel accepts dragged files")
        let hosting = container.subviews.flatMap(\.subviews)
        check(hosting.allSatisfy { $0.registeredDraggedTypes.isEmpty }, "SwiftUI content doesn't intercept file drops")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("IVY drop check \(UUID().uuidString).txt")
        try? Data("drop".utf8).write(to: file)
        defer {
            env.shelf.remove(file)
            try? FileManager.default.removeItem(at: file)
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("IVY.dropcheck.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        // Bottom-right of the dashboard body: inside the shelf, away from the AirDrop zone.
        let shape = model.shapeSize
        let point = CGPoint(x: container.bounds.midX + shape.width / 2 - 60, y: container.bounds.height - shape.height + 40)
        let drag = FakeDrag(pasteboard: pasteboard, location: point, window: controller.panel)

        check(container.draggingEntered(drag) == .copy, "A file drag is accepted as a copy (never a move)")
        await settle()
        check(model.tab == .shelf && model.isDropTargeted, "Dragging files switches to the shelf and highlights it")
        if let zone = model.airDropZone {
            let airDrop = FakeDrag(pasteboard: pasteboard, location: CGPoint(x: zone.midX, y: container.bounds.height - zone.midY),
                                   window: controller.panel)
            _ = container.draggingUpdated(airDrop)
            check(model.isAirDropTargeted && !model.isDropTargeted, "The AirDrop zone is targeted separately")
            _ = container.draggingUpdated(drag)
        } else {
            check(false, "The shelf reports its AirDrop zone")
        }
        check(container.performDragOperation(drag), "Dropping onto the shelf succeeds")
        check(env.shelf.items.contains(file), "The dropped file appears on the shelf")
        model.closeDashboard()
        check(model.mode == .dashboard, "The dashboard stays open right after a drop")
        await settle()
    }
}

/// Minimal dragging info for the drop check.
private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?

    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
        draggingPasteboard = pasteboard
        draggingLocation = location
        draggingDestinationWindow = window
    }

    var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .generic] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
#endif
