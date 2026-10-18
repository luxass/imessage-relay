// swift-tools-version:6.3
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "HummingbirdOpenAPI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HummingbirdOpenAPI", targets: ["HummingbirdOpenAPI"]),
        .library(name: "HummingbirdOpenAPIModels", targets: ["HummingbirdOpenAPIModels"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.4.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    ],
    targets: [
        .macro(
            name: "HummingbirdOpenAPIMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
        .target(name: "HummingbirdOpenAPIModels", dependencies: ["HummingbirdOpenAPIMacros"]),
        .target(
            name: "HummingbirdOpenAPI",
            dependencies: [
                "HummingbirdOpenAPIModels",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .testTarget(name: "ModelTests", dependencies: ["HummingbirdOpenAPIModels"]),
        .testTarget(
            name: "MacroTests",
            dependencies: [
                "HummingbirdOpenAPIMacros",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "RouterTests",
            dependencies: [
                "HummingbirdOpenAPI",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
