// swift-tools-version: 6.2

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "DiagnosticFixItExample",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(name: "swift-macro-plugin-utilities", path: "../.."),
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            "602.0.0"..<"604.0.0"
        ),
    ],
    targets: [
        .macro(
            name: "RequireFinalMacros",
            dependencies: [
                .product(name: "MacroPluginUtilities", package: "swift-macro-plugin-utilities"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "RequireFinal",
            dependencies: ["RequireFinalMacros"]
        ),
        .executableTarget(
            name: "DiagnosticFixItExample",
            dependencies: ["RequireFinal"]
        ),
        .testTarget(
            name: "RequireFinalMacrosTests",
            dependencies: [
                "RequireFinal",
                "RequireFinalMacros",
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
