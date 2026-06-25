// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "apple-health-data-bridge",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "BridgeKit", targets: ["BridgeKit"]),
        .library(name: "HealthBridgeConfig", targets: ["HealthBridgeConfig"]),
        .library(name: "HealthBridgeParsing", targets: ["HealthBridgeParsing"]),
        .executable(name: "healthbridge", targets: ["healthbridge"]),
    ],
    dependencies: [
        // Verified resolved versions: FHIRModels 0.9.3, swift-argument-parser 1.8.2.
        .package(url: "https://github.com/apple/FHIRModels.git", .upToNextMinor(from: "0.9.3")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", .upToNextMinor(from: "1.8.2")),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(name: "BridgeKit"),
        .target(name: "HealthBridgeConfig", dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]),
        .target(
            name: "HealthBridgeParsing",
            dependencies: ["BridgeKit", .product(name: "ModelsR4", package: "FHIRModels")]
        ),
        .executableTarget(
            name: "healthbridge",
            dependencies: [
                "HealthBridgeParsing", "HealthBridgeConfig", "BridgeKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "bridge-eval",
            dependencies: [
                "HealthBridgeParsing", "BridgeKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "BridgeKitTests", dependencies: ["BridgeKit"]),
        .testTarget(name: "HealthBridgeConfigTests", dependencies: ["HealthBridgeConfig"]),
        .testTarget(
            name: "HealthBridgeParsingTests",
            dependencies: ["HealthBridgeParsing", "BridgeKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "healthbridgeTests",
            dependencies: ["healthbridge", "BridgeKit", "HealthBridgeConfig"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "BridgeEvalTests",
            dependencies: ["bridge-eval", "HealthBridgeParsing", "BridgeKit"],
            resources: [.copy("Fixtures")]
        ),
        // healthbridgeTests in Task 9. A test target with no .swift sources fails to build,
        // so each is declared in the task that creates its first test file.
    ]
)
