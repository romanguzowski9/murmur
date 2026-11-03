// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "MurmurCore"),
        .executableTarget(name: "Murmur", dependencies: ["MurmurCore"]),
        .executableTarget(name: "murmur-cli", dependencies: ["MurmurCore"]),
        .executableTarget(name: "murmur-mcp", dependencies: ["MurmurCore"]),
    ],
    swiftLanguageModes: [.v5]
)
