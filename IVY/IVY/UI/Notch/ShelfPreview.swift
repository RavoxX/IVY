import AppKit
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// Quick Look thumbnails for shelf files (images, PDFs, videos, documents), cached in memory.
@MainActor
final class FileThumbnailCache {
    static let shared = FileThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func cached(_ url: URL, size: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, size))
    }

    func thumbnail(for url: URL, size: CGFloat, scale: CGFloat) async -> NSImage? {
        if let image = cached(url, size: size) { return image }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: scale,
                                                   representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = representation.nsImage
        cache.setObject(image, forKey: key(url, size))
        return image
    }

    private func key(_ url: URL, _ size: CGFloat) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(Int(size))|\(modified)" as NSString
    }
}

/// A file's preview: the Finder icon right away, replaced by a Quick Look thumbnail once ready.
struct FileThumbnail: View {
    let url: URL
    var size: CGFloat = 52
    @State private var thumbnail: NSImage?
    @Environment(\.displayScale) private var scale

    private var type: UTType? { UTType(filenameExtension: url.pathExtension) }
    private var isMedia: Bool { type?.conforms(to: .image) == true || type?.conforms(to: .movie) == true }

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: isMedia ? .fill : .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: isMedia ? 9 : 3, style: .continuous))
                    .overlay {
                        if isMedia {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                        }
                    }
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: size, height: size)
            }
            if type?.conforms(to: .movie) == true, thumbnail != nil {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(size * 0.1)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            if let cached = FileThumbnailCache.shared.cached(url, size: size) {
                thumbnail = cached
                return
            }
            let image = await FileThumbnailCache.shared.thumbnail(for: url, size: size, scale: scale)
            withAnimation(.easeOut(duration: 0.2)) { thumbnail = image }
        }
    }
}

/// Full Quick Look preview (the Finder Space-bar panel) for shelf files.
@MainActor
final class ShelfQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = ShelfQuickLook()
    private var urls: [URL] = []

    func show(_ urls: [URL], selecting url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        // IVY is a background app; activate so the panel comes to the front and takes keys.
        NSApp.activate(ignoringOtherApps: true)
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = urls.firstIndex(of: url) ?? 0
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}

enum FileDetails {
    /// "PDF · 2.4 MB", "Folder", "PNG image · 640 KB".
    static func summary(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return "Folder" }
        let ext = url.pathExtension.uppercased()
        let kind = ext.isEmpty || ext.count > 5 ? (values?.localizedTypeDescription ?? "File") : ext
        guard let bytes = values?.fileSize else { return kind }
        return "\(kind) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }
}
