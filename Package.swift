// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-macro-plugin-utilities",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "swift-source-guardrails", targets: ["SwiftSourceGuardrails"]),
        .library(
            name: "MacroPluginUtilities",
            targets: ["MacroPluginUtilities"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            "602.0.0"..<"604.0.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "SwiftSourceGuardrails",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "SwiftSourceGuardrailsTests",
            dependencies: ["SwiftSourceGuardrails"],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "MacroPluginUtilities",
            dependencies: [
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "MacroPluginUtilitiesTests",
            dependencies: [
                "MacroPluginUtilities",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
