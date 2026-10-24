// swift-tools-version:6.3
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "HummingbirdOpenAPI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HummingbirdOpenAPIModels", targets: ["HummingbirdOpenAPIModels"]),
        .library(name: "HummingbirdOpenAPI", targets: ["HummingbirdOpenAPI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.4.0"),
        .package(url: "https://github.com/mattpolzin/OpenAPIKit.git", from: "7.0.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0"),
    ],
    targets: [
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
            ]
        ),
        .testTarget(
            name: "SchemaTests",
            dependencies: ["HummingbirdOpenAPIModels"]
        ),
        .testTarget(
            name: "MacroTests",
            dependencies: [
                "HummingbirdOpenAPIMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "EndpointTests",
            dependencies: [
                "HummingbirdOpenAPI",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
