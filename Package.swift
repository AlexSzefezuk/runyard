// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Runyard",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "RunyardCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Runyard",
            dependencies: ["RunyardCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "RunyardCLI",
            dependencies: ["RunyardCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
