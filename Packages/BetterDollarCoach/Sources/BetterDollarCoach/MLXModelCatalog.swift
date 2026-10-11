import Foundation

/// An open-weight model that can be downloaded from Hugging Face and run on the iPhone with MLX.
public struct MLXModelSpec: Identifiable, Sendable, Hashable {
    public let id: String
    public let displayName: String
    /// Hugging Face repository, for example "mlx-community/Qwen3.5-2B-4bit".
    public let repo: String
    /// Pinned commit so every install runs exactly the reviewed weights.
    public let revision: String
    public let approxBytes: Int64
    public let license: String
    public let licenseURL: URL
    public let summary: String
    public let isRecommended: Bool
    /// Rough minimum iPhone RAM in GB for a comfortable run.
    public let minimumRAMGB: Int

    public var sizeText: String { ByteCountFormatter.string(fromByteCount: approxBytes, countStyle: .file) }
    public var pageURL: URL { URL(string: "https://huggingface.co/\(repo)/tree/\(revision)")! }
}

/// Models chosen for a phone: small enough to download and run, good at following instructions,
/// and supported by mlx-swift-lm 3.32.3. Revisions were verified against the Hugging Face API, and each
/// model was downloaded and asked a budget question in the BD_MLX_SMOKE test before it was listed.
public enum MLXModelCatalog {
    public static let all: [MLXModelSpec] = [
        MLXModelSpec(id: "qwen3.5-4b", displayName: "Qwen 3.5 4B", repo: "mlx-community/Qwen3.5-4B-MLX-4bit",
                     revision: "32f3e8ecf65426fc3306969496342d504bfa13f3", approxBytes: 3_060_000_000,
                     license: "Apache 2.0", licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
                     summary: "Most accurate with your numbers in our tests. Best on recent Pro iPhones.",
                     isRecommended: true, minimumRAMGB: 8),
        MLXModelSpec(id: "qwen3.5-2b", displayName: "Qwen 3.5 2B", repo: "mlx-community/Qwen3.5-2B-4bit",
                     revision: "674aaa7240b91e8012fcad5d791b7dfe5ba90207", approxBytes: 1_750_000_000,
                     license: "Apache 2.0", licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
                     summary: "Quicker and half the size, but mixes up figures more often.",
                     isRecommended: false, minimumRAMGB: 6),
        MLXModelSpec(id: "gemma-4-e2b", displayName: "Gemma 4 E2B", repo: "mlx-community/gemma-4-e2b-it-4bit",
                     revision: "238767527555cb75a05732a84dff5d6ba0dd6809", approxBytes: 3_580_000_000,
                     license: "Gemma Terms of Use", licenseURL: URL(string: "https://ai.google.dev/gemma/terms")!,
                     summary: "Google's on-device model. Clear, friendly answers; the largest download.",
                     isRecommended: false, minimumRAMGB: 8),
        MLXModelSpec(id: "llama-3.2-3b", displayName: "Llama 3.2 3B", repo: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                     revision: "7f0dc925e0d0afb0322d96f9255cfddf2ba5636e", approxBytes: 1_820_000_000,
                     license: "Llama 3.2 Community License", licenseURL: URL(string: "https://github.com/meta-llama/llama-models/blob/main/models/llama3_2/LICENSE")!,
                     summary: "Meta's compact model. Steady and conversational, but slower.",
                     isRecommended: false, minimumRAMGB: 6),
        MLXModelSpec(id: "lfm2.5-1.2b", displayName: "LFM2.5 1.2B", repo: "mlx-community/LFM2.5-1.2B-Instruct-4bit",
                     revision: "dee2f8a2786e6648bb644a7ca40652842490034b", approxBytes: 660_000_000,
                     license: "LFM Open License", licenseURL: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct/blob/main/LICENSE")!,
                     summary: "Fastest and smallest. Works on older iPhones; answers are simpler.",
                     isRecommended: false, minimumRAMGB: 4)
    ]

    public static var recommended: MLXModelSpec { all.first(where: \.isRecommended) ?? all[0] }

    public static func spec(id: String) -> MLXModelSpec? { all.first { $0.id == id } }
}
