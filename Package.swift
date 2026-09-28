// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VibeNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VibeNotch", path: "Sources/VibeNotch")
    ]
)
