// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Inky",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "InkyCore"),
        .executableTarget(name: "Inky", dependencies: ["InkyCore"]),
        .testTarget(name: "InkyCoreTests", dependencies: ["InkyCore"]),
    ],
    swiftLanguageModes: [.v5]
)
