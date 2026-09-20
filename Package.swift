// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "imessage-relay",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "relay-server", targets: ["RelayCLI"]),
        .library(name: "RelayCore", targets: ["RelayCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .target(
            name: "RelayCore",
            dependencies: [.product(name: "NIOPosix", package: "swift-nio")]
        ),
        .target(
            name: "RelayServer",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdRouter", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                "RelayCore",
            ]
        ),
        .executableTarget(
            name: "RelayCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "RelayServer",
            ]
        ),
        .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"]),
        .testTarget(
            name: "RelayServerTests",
            dependencies: [
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                "RelayServer",
                "RelayCore",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
