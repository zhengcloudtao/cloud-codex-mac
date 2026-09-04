// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CloudCodex",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CloudCodex", targets: ["CloudCodex"])
    ],
    targets: [
        .executableTarget(
            name: "CloudCodex",
            path: "Sources/CodexControlNative"
        ),
        .testTarget(
            name: "CloudCodexTests",
            dependencies: ["CloudCodex"],
            path: "Tests/CodexControlNativeTests"
        )
    ]
)
