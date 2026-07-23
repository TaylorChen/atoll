// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Atoll",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Atoll", path: "Sources/Atoll"),
        .testTarget(name: "AtollTests", dependencies: ["Atoll"])
    ]
)
