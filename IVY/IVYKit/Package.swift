// swift-tools-version: 6.0
import PackageDescription

/// IVYKit holds IVY's platform-independent core: the modifier gesture state machine,
/// command routing, the tool/agent architecture, history, parsing and security policy.
/// It is deliberately free of UI code so it can be unit tested with `swift test`.
let package = Package(
    name: "IVYKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IVYCore", targets: ["IVYCore"]),
    ],
    targets: [
        .target(
            name: "IVYCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "IVYCoreTests",
            dependencies: ["IVYCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
