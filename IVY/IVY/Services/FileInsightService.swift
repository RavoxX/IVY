import Foundation
import ImageIO
import IVYCore
import UniformTypeIdentifiers
import Vision

/// Describes a file for "Ask IVY about this file", entirely on-device.
///
/// IVY's language model reads text only, so images are summarized with Apple Vision (scene
/// labels, text, people, animals, QR/barcodes) and documents contribute their text. Other files
/// still get their name, kind and size, so IVY can at least say what they are. Location data is
/// never included.
enum FileInsightService {
    static func context(for url: URL) -> String {
        var lines = ["File: \(url.lastPathComponent)"]
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .isDirectoryKey,
                                                       .contentModificationDateKey])
        if let kind = values?.localizedTypeDescription { lines.append("Kind: \(kind)") }
        if let size = values?.fileSize { lines.append("Size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))") }
        if let modified = values?.contentModificationDate {
            lines.append("Modified: \(modified.formatted(date: .abbreviated, time: .shortened))")
        }

        let type = UTType(filenameExtension: url.pathExtension)
        if values?.isDirectory == true {
            lines.append(folderListing(url))
        } else if type?.conforms(to: .image) == true {
            lines.append(FileQuestion.imageGuidance)
            lines.append(imageAnalysis(url))
        } else if let text = try? ContextAttachmentService.read(url).text {
            lines.append("Content:\n\(text.prefix(8_000))")
        } else {
            lines.append("IVY can't read this file's content; describe it from its name and kind.")
        }
        return lines.joined(separator: "\n")
    }

    private static func folderListing(_ url: URL) -> String {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let visible = items.filter { !$0.hasPrefix(".") }.sorted()
        return "Folder with \(visible.count) items: " + visible.prefix(30).joined(separator: ", ")
    }

    private static func imageAnalysis(_ url: URL) -> String {
        var lines: [String] = []
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
                lines.append("Dimensions: \(width) × \(height) px")
            }
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            if let model = tiff?[kCGImagePropertyTIFFModel] as? String { lines.append("Camera: \(model)") }
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            if let taken = exif?[kCGImagePropertyExifDateTimeOriginal] as? String { lines.append("Taken: \(taken)") }
        }

        let handler = VNImageRequestHandler(url: url)
        let classify = VNClassifyImageRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.automaticallyDetectsLanguage = true
        let faces = VNDetectFaceRectanglesRequest()
        let humans = VNDetectHumanRectanglesRequest()
        let animals = VNRecognizeAnimalsRequest()
        let codes = VNDetectBarcodesRequest()
        try? handler.perform([classify, text, faces, humans, animals, codes])

        let labels = (classify.results ?? [])
            .filter { $0.confidence >= 0.15 }
            .prefix(12)
            .map { "\($0.identifier.replacingOccurrences(of: "_", with: " ")) \(Int($0.confidence * 100))%" }
        lines.append(labels.isEmpty ? "Scene labels: none confident" : "Scene labels: " + labels.joined(separator: ", "))

        let people = max(faces.results?.count ?? 0, humans.results?.count ?? 0)
        if people > 0 { lines.append("People: \(people)") }
        let animalNames = (animals.results ?? []).compactMap { $0.labels.first?.identifier }
        if !animalNames.isEmpty { lines.append("Animals: " + animalNames.joined(separator: ", ")) }
        let payloads = (codes.results ?? []).compactMap(\.payloadStringValue)
        if !payloads.isEmpty { lines.append("Codes: " + payloads.prefix(3).joined(separator: " | ")) }

        let words = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        lines.append(words.isEmpty ? "Text in image: none" : "Text in image:\n\(words.prefix(4_000))")
        return lines.joined(separator: "\n")
    }
}
