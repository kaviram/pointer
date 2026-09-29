// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pointer",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Pointer",
            path: "Sources/Pointer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
