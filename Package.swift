// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Runyard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Runyard",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
