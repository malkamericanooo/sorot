// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sorot",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Sorot", path: "Sources/Sorot")
    ]
)
