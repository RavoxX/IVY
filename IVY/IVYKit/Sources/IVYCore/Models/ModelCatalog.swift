import Foundation

public enum ModelKind: String, Codable, Sendable, CaseIterable {
    case llm = "LLM"
    case whisper = "Whisper"
    case kokoro = "Kokoro"
}

/// A downloadable local model. Only metadata lives in settings; weights live under
/// `~/Library/Application Support/IVY/Models/<kind>/<folder>`.
public struct ModelDescriptor: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var kind: ModelKind
    public var displayName: String
    /// Hugging Face repository (MLX format).
    public var repo: String
    public var approximateBytes: Int64
    public var notes: String

    public init(id: String, kind: ModelKind, displayName: String, repo: String, approximateBytes: Int64, notes: String) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.repo = repo
        self.approximateBytes = approximateBytes
        self.notes = notes
    }

    public var folderName: String { repo.split(separator: "/").last.map(String.init) ?? id }

    public func directory(in modelsFolder: URL) -> URL {
        modelsFolder.appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: approximateBytes, countStyle: .file)
    }
}

public enum ModelCatalog {
    // Default LLM: Qwen3 4B, 4-bit MLX quantization. ~2.3 GB on disk, ~2.6 GB resident,
    // strong instruction following and native tool calling via its chat template.
    public static let defaultLLM = ModelDescriptor(
        id: "qwen3-4b-4bit", kind: .llm, displayName: "Qwen3 4B (4-bit)",
        repo: "mlx-community/Qwen3-4B-4bit", approximateBytes: 2_280_000_000,
        notes: "Default. Fast on MacBook Air, native tool calling.")

    public static let llms: [ModelDescriptor] = [
        defaultLLM,
        ModelDescriptor(id: "qwen3-1.7b-4bit", kind: .llm, displayName: "Qwen3 1.7B (4-bit)",
                        repo: "mlx-community/Qwen3-1.7B-4bit", approximateBytes: 980_000_000,
                        notes: "Smallest and fastest; weaker tool use."),
        ModelDescriptor(id: "qwen3-8b-4bit", kind: .llm, displayName: "Qwen3 8B (4-bit)",
                        repo: "mlx-community/Qwen3-8B-4bit", approximateBytes: 4_620_000_000,
                        notes: "Better answers; needs 16 GB+ memory."),
        ModelDescriptor(id: "qwen3-14b-4bit", kind: .llm, displayName: "Qwen3 14B (4-bit)",
                        repo: "mlx-community/Qwen3-14B-4bit", approximateBytes: 8_320_000_000,
                        notes: "Best answers and writing; about half the speed of 8B. Needs 24 GB+ memory."),
    ]

    public static let defaultWhisper = ModelDescriptor(
        id: "whisper-large-v3-turbo", kind: .whisper, displayName: "Whisper Large v3 Turbo",
        repo: "mlx-community/whisper-large-v3-turbo", approximateBytes: 1_610_000_000,
        notes: "Default. Accurate, multilingual, fast on Apple Silicon.")

    public static let whispers: [ModelDescriptor] = [
        defaultWhisper,
        ModelDescriptor(id: "whisper-small-mlx", kind: .whisper, displayName: "Whisper Small",
                        repo: "mlx-community/whisper-small-mlx", approximateBytes: 480_000_000,
                        notes: "Smaller download, lower accuracy."),
        ModelDescriptor(id: "whisper-base-mlx", kind: .whisper, displayName: "Whisper Base",
                        repo: "mlx-community/whisper-base-mlx", approximateBytes: 145_000_000,
                        notes: "Tiny and fast; English works best."),
    ]

    public static let kokoro = ModelDescriptor(
        id: "kokoro-82m-bf16", kind: .kokoro, displayName: "Kokoro 82M",
        repo: "mlx-community/Kokoro-82M-bf16", approximateBytes: 370_000_000,
        notes: "Local neural TTS via MLX (mlx-audio).")

    public static var all: [ModelDescriptor] { llms + whispers + [kokoro] }

    public static func descriptor(id: String) -> ModelDescriptor? {
        all.first { $0.id == id }
    }

    /// A subset of Kokoro's voices (American/British English).
    public static let kokoroVoices: [(id: String, name: String)] = [
        ("af_heart", "Heart (US, female)"),
        ("af_bella", "Bella (US, female)"),
        ("af_nicole", "Nicole (US, female)"),
        ("af_sky", "Sky (US, female)"),
        ("am_adam", "Adam (US, male)"),
        ("am_michael", "Michael (US, male)"),
        ("bf_emma", "Emma (UK, female)"),
        ("bm_george", "George (UK, male)"),
    ]
}
