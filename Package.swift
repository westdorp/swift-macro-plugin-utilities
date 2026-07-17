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
            from: "602.0.0"
        ),
    ],
    targets: [
        .target(
            name: "MacroPluginUtilities",
            dependencies: [
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "MacroPluginUtilitiesTests",
            dependencies: [
                "MacroPluginUtilities",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
