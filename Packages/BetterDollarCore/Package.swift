// swift-tools-version: 6.2
import PackageDescription

// BetterDollarCore holds the budget model, money math, Plaid client, imports and backups.
// It has no third-party dependencies so it can be audited on its own.
let package = Package(
    name: "BetterDollarCore",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "BetterDollarCore", targets: ["BetterDollarCore"])],
    targets: [
        .target(name: "BetterDollarCore"),
        .testTarget(name: "BetterDollarCoreTests", dependencies: ["BetterDollarCore"])
    ],
    swiftLanguageModes: [.v6]
)
