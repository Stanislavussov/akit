// swift-tools-version: 6.0
// AKit core: data model, harness adapters, file access. No UI.
import PackageDescription

let package = Package(
    name: "AKitCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "AKitCore", targets: ["AKitCore"])],
    targets: [
        .target(name: "AKitCore"),
        .testTarget(name: "AKitCoreTests", dependencies: ["AKitCore"]),
    ]
)
