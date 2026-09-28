// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CloudCodex",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CloudCodex", targets: ["CloudCodex"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "CloudCodex",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/CodexControlNative"
        ),
        .testTarget(
            name: "CloudCodexTests",
            dependencies: ["CloudCodex"],
            path: "Tests/CodexControlNativeTests"
        )
    ]
)
