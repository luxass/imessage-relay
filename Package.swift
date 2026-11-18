// swift-tools-version:6.3
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "imessage-relay",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "imessage-relay", targets: ["RelayCLI"]),
        .executable(name: "imessage-relay-app", targets: ["RelayApp"]),
        .executable(name: "imessage-relay-openapi", targets: ["RelayOpenAPIExport"]),
        .library(name: "RelayCore", targets: ["RelayCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/PhoneNumberKit/PhoneNumberKit.git", from: "5.0.9"),
        .package(url: "https://github.com/mattpolzin/OpenAPIKit.git", from: "7.0.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
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
                "HummingbirdOpenAPIModels",
                .product(name: "OpenAPIKit", package: "OpenAPIKit"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
            ]
        ),
        .target(
            name: "RelayServer",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                "HummingbirdOpenAPI",
                "HummingbirdOpenAPIModels",
                .product(name: "OpenAPIKit", package: "OpenAPIKit"),
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
            name: "RelayOpenAPIExport",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "RelayServer",
            ]
        ),
        .target(
            name: "RelayAppKit",
            dependencies: ["RelayServer", "RelayCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .macro(
            name: "HummingbirdOpenAPIMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "HummingbirdOpenAPIModels",
            dependencies: [
                "HummingbirdOpenAPIMacros",
                .product(name: "OpenAPIKit", package: "OpenAPIKit"),
            ]
        ),
        .target(
            name: "HummingbirdOpenAPI",
            dependencies: [
                "HummingbirdOpenAPIModels",
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            exclude: ["README.md"]
        ),
        .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"]),
        .executableTarget(name: "RelayApp", dependencies: ["RelayAppKit"]),
        .testTarget(name: "RelayAppTests", dependencies: ["RelayAppKit"]),
        .testTarget(
            name: "RelayServerTests",
            dependencies: [
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                "HummingbirdOpenAPIModels",
                .product(name: "OpenAPIKit", package: "OpenAPIKit"),
                "RelayServer",
                "RelayCore",
            ]
        ),
        .testTarget(name: "HummingbirdOpenAPISchemaTests", dependencies: ["HummingbirdOpenAPIModels"]),
        .testTarget(
            name: "HummingbirdOpenAPIMacroTests",
            dependencies: [
                "HummingbirdOpenAPIMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "HummingbirdOpenAPIEndpointTests",
            dependencies: [
                "HummingbirdOpenAPI",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
