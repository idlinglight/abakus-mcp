// swift-tools-version: 6.2
import PackageDescription

// Dependencies only from github.com/apple and github.com/swiftlang (ADR-0001).
let package = Package(
    name: "abakus",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "abakus", targets: ["abakus"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        // All tool behaviour, defined once; the MCP server and the CLI are thin layers over it.
        .target(name: "AbakusCore"),
        // MCP over stdio: JSON-RPC framing, protocol revisions, exposing the tool catalog (ADR-0002).
        .target(name: "AbakusMCP", dependencies: ["AbakusCore"]),
        .executableTarget(
            name: "abakus",
            dependencies: [
                "AbakusCore",
                "AbakusMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "AbakusCoreTests", dependencies: ["AbakusCore"]),
        .testTarget(name: "AbakusMCPTests", dependencies: ["AbakusMCP", "AbakusCore"]),
    ]
)
