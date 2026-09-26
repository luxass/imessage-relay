// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "imessage-relay",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "imessage-relay", targets: ["RelayCLI"]),
        .executable(name: "imessage-relay-app", targets: ["RelayApp"]),
        .library(name: "RelayCore", targets: ["RelayCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/PhoneNumberKit/PhoneNumberKit.git", from: "5.0.9"),
    ],
    targets: [
        .target(
            name: "AttributedBodyBridge",
            path: "Sources/AttributedBodyBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "RelayCore",
            dependencies: [
                "AttributedBodyBridge",
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
            ]
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
        .executableTarget(
            name: "RelayApp",
            dependencies: ["RelayServer", "RelayCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"]),
        .testTarget(name: "RelayAppTests", dependencies: ["RelayApp"]),
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
