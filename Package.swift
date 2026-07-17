// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-macro-plugin-utilities",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(
            name: "MacroPluginUtilities",
            targets: ["MacroPluginUtilities"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            "602.0.0"..<"604.0.0"
        ),
    ],
    targets: [
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
