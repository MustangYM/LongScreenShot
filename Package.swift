// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LongScreenShot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LongScreenShot", targets: ["LongScreenShot"])
    ],
    targets: [
        .executableTarget(
            name: "LongScreenShot",
            path: "Sources/LongScreenShot",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LongScreenShotTests",
            dependencies: ["LongScreenShot"],
            path: "Tests/LongScreenShotTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
