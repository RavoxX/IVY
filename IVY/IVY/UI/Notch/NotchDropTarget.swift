import AppKit
import IVYCore
import os

/// Receives files dragged onto the notch panel for the shelf (or the AirDrop zone).
///
/// This runs in AppKit on the panel itself rather than through SwiftUI's `onDrop`: file URLs
/// are read synchronously from the drag pasteboard during the drop, so a drop the panel
/// accepted can never come back empty. File promises (screenshot thumbnails, Mail and
/// Photos) are received into IVY's shelf folder. The panel always answers with `.copy`, so
/// the source app never moves or deletes the original.
@MainActor
final class NotchDropTarget {
    static let types: [NSPasteboard.PasteboardType] =
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    private let model: NotchViewModel
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(model: NotchViewModel) {
        self.model = model
    }

    /// Promised files land here; they stay as long as they are on the shelf.
    static var inbox: URL { AppPaths.applicationSupport.appendingPathComponent("Shelf", isDirectory: true) }

    /// True while the system drag pasteboard holds files and the mouse button is down.
    static var isDraggingFiles: Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return false }
        let available = Set(NSPasteboard(name: .drag).types ?? [])
        return !available.isDisjoint(with: types)
    }

    func entered(_ info: NSDraggingInfo, in view: NSView) -> NSDragOperation {
        guard accepts(info) else { return [] }
        model.openDashboard(tab: .shelf)
        return updated(info, in: view)
    }

    func updated(_ info: NSDraggingInfo, in view: NSView) -> NSDragOperation {
        guard accepts(info) else { return [] }
        let overAirDrop = isOverAirDrop(info, in: view)
        if model.isAirDropTargeted != overAirDrop { model.isAirDropTargeted = overAirDrop }
        if model.isDropTargeted == overAirDrop { model.isDropTargeted = !overAirDrop }
        return .copy
    }

    func exited() {
        model.isDropTargeted = false
        model.isAirDropTargeted = false
    }

    func perform(_ info: NSDraggingInfo, in view: NSView) -> Bool {
        let toAirDrop = isOverAirDrop(info, in: view)
        exited()
        let pasteboard = info.draggingPasteboard
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            deliver(urls, toAirDrop: toAirDrop)
            return true
        }
        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        guard !promises.isEmpty else {
            Log.ui.error("Drop contained no readable files")
            return false
        }
        let inbox = Self.inbox
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        for promise in promises {
            promise.receivePromisedFiles(atDestination: inbox, options: [:], operationQueue: promiseQueue) { [weak self] url, error in
                if let error {
                    Log.ui.error("Promised file failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                DispatchQueue.main.async { self?.deliver([url], toAirDrop: toAirDrop) }
            }
        }
        model.didReceiveDrop()
        return true
    }

    private func deliver(_ urls: [URL], toAirDrop: Bool) {
        if toAirDrop, ShelfStore.airDrop(urls) {
            model.didReceiveDrop(showShelf: false)
        } else {
            model.env.shelf.add(urls)
            model.didReceiveDrop()
        }
    }

    private func accepts(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || info.draggingPasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    /// The AirDrop zone's frame comes from SwiftUI in top-left window coordinates.
    private func isOverAirDrop(_ info: NSDraggingInfo, in view: NSView) -> Bool {
        guard model.mode == .dashboard, model.tab == .shelf, let zone = model.airDropZone else { return false }
        let point = info.draggingLocation
        return zone.contains(CGPoint(x: point.x, y: view.bounds.height - point.y))
    }
}
