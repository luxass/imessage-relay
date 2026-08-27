// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "imessage-relay",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "relay-server", targets: ["relay-server"]),
        .library(name: "RelayCore", targets: ["RelayCore"]),
        .library(name: "RelaySender", targets: ["RelaySender"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        .target(name: "RelayCore"),
        .target(name: "RelaySender", dependencies: ["RelayCore"]),
        .executableTarget(
            name: "relay-server",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                "RelayCore",
                "RelaySender",
            ]
        ),
        .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"]),
        .testTarget(name: "RelayServerTests", dependencies: ["relay-server", "RelayCore"]),
    ],
    // Language mode 5 for now: relaxes strict-concurrency checking so the
    // skeleton compiles without actors everywhere. Tighten to Swift 6 mode
    // once the store is actor-isolated properly.
    swiftLanguageModes: [.v5]
)
