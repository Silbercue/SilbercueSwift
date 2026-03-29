// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SilbercueSwift",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "SilbercueSwiftCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        .executableTarget(
            name: "SilbercueSwift",
            dependencies: [
                "SilbercueSwiftCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "SmartContextTests",
            dependencies: ["SilbercueSwiftCore"]
        ),
    ]
)
