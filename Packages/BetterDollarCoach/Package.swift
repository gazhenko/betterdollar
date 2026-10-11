// swift-tools-version: 6.2
import PackageDescription

// The on-device financial coach: Apple Intelligence (Foundation Models) and
// downloadable open-weight models running locally through MLX.
let package = Package(
    name: "BetterDollarCoach",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "BetterDollarCoach", targets: ["BetterDollarCoach"])],
    dependencies: [
        .package(path: "../BetterDollarCore"),
        // traits: [] turns off FoundationModelsIntegration, which needs the 27 SDKs.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3", traits: []),
        // Tokenizers for loading a downloaded model from a local folder.
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4")
    ],
    targets: [
        .target(name: "BetterDollarCoach", dependencies: [
            .product(name: "BetterDollarCore", package: "BetterDollarCore"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers")
        ]),
        .testTarget(name: "BetterDollarCoachTests", dependencies: ["BetterDollarCoach"])
    ],
    swiftLanguageModes: [.v6]
)
