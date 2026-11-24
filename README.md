# swift-macro-plugin-utilities

`swift-macro-plugin-utilities` provides syntactic queries, structured diagnostics, and deterministic fix-its for Swift macro plugins, alongside the [`swift-source-guardrails`](Documentation/SourceGuardrails.md) syntax checker.

## Package stack

This package is the standalone foundation layer of the three-package stack and has no dependency on its downstream consumers (`swift-provider-message` or `swift-network-extension-macros`):

```text
swift-macro-plugin-utilities          (diagnostics, fix-its, syntax queries, swift-source-guardrails)
      ▲
      │
swift-provider-message                (@ProviderMessage typed RPC, wire codec, @XPC bridge)
      ▲
      │
swift-network-extension-macros        (@ProviderConfiguration, @TunnelStateMachine, @ConnectionState, @TunnelDiagnostics, NE adapter)
```

`MacroPluginUtilities` is a utility library for Swift macro-plugin implementations. It is not a macro framework, semantic type checker, or runtime library.

## Quick start

Requires Swift 6.2 or later on macOS 13 or later. Add `import CompilerPluginSupport`, both package dependencies, and the macro and library targets to `Package.swift` (see [`Examples/DiagnosticFixItExample/Package.swift`](Examples/DiagnosticFixItExample/Package.swift)):

```swift
// swift-tools-version: 6.2

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "DiagnosticFixItExample",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/westdorp/swift-macro-plugin-utilities.git", .upToNextMinor(from: "0.7.0")),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "602.0.0"..<"604.0.0"),
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
        .target(name: "RequireFinal", dependencies: ["RequireFinalMacros"]),
    ]
)
```

If another dependency already exposes `MacroPluginUtilities`, pass `moduleAliases: ["MacroPluginUtilities": "PluginUtilities"]` on `.product(...)` and write `import PluginUtilities` in your macro target.

In [`Examples/DiagnosticFixItExample`](Examples/DiagnosticFixItExample), [`RequireFinalMacro.swift`](Examples/DiagnosticFixItExample/Sources/RequireFinalMacros/RequireFinalMacro.swift) accepts `final` classes without a diagnostic (rejecting `open final` classes and already-`final` classes with unconditional `open` members, while conditional-only `#if` open members do not trigger a diagnostic on an already-`final` class), diagnoses non-class declarations, `open` classes, non-final classes with `open` members, and non-final classes with nested or local classes without offering a fix-it, and for other non-final classes emits one structured diagnostic with a deterministic fix-it (syntactic macro expansion inspects only the attached class body, so confirm no sibling or cross-file subclasses exist before applying the fix-it):

```swift
let fixIt = makeAddFinalFixIt(
    for: classDecl,
    fixItMessage: MacroFixItMessage("Add 'final' modifier", domain: diagnosticDomain)
)
context.diagnose(
    classDecl.name,
    domain: diagnosticDomain,
    id: RequireFinalDiagnosticID.missingFinal,
    what: "@RequireFinal can only be applied to a final class.",
    why: "Subclasses would bypass the type's invariants.",
    how: "Confirm no external declaration subclasses this type, then add the 'final' modifier to this class declaration.",
    fixIts: [fixIt]
)
return []
```

[`RequireFinalPlugin.swift`](Examples/DiagnosticFixItExample/Sources/RequireFinalMacros/RequireFinalPlugin.swift) registers `RequireFinalMacro` in a `CompilerPlugin`, and [`RequireFinal.swift`](Examples/DiagnosticFixItExample/Sources/RequireFinal/RequireFinal.swift) exposes `@attached(peer) public macro RequireFinal()`.

Attaching `@RequireFinal` to `class Session {}` produces:

```text
error: WHAT: @RequireFinal can only be applied to a final class. WHY: Subclasses would bypass the type's invariants. HOW: Confirm no external declaration subclasses this type, then add the 'final' modifier to this class declaration.
fix-it: Add 'final' modifier -> final class Session {}
```

Run `swift test --package-path Examples/DiagnosticFixItExample` to verify every case, or remove `final` from `Session` in [`Examples/DiagnosticFixItExample/Sources/DiagnosticFixItExample/main.swift`](Examples/DiagnosticFixItExample/Sources/DiagnosticFixItExample/main.swift) and run `swift build --package-path Examples/DiagnosticFixItExample` to see the compiler emit the diagnostic directly.

## Diagnostic contract

Macro diagnostics must state what is wrong, why it matters, and how to fix it. `MacroDiagnosticMessage` accepts those fragments directly, preserves a stable caller-defined identity and severity, and normalizes whitespace without interpreting diagnostic content:

```swift
let message = MacroDiagnosticMessage(
    domain: "ExampleMacro",
    id: "missing-state",
    what: "State enum is missing.",
    why: "The macro needs a finite state domain.",
    how: "Add a nested State enum.",
    severity: .warning
)
```

The rendered text is:

```text
WHAT: State enum is missing. WHY: The macro needs a finite state domain. HOW: Add a nested State enum.
```

For error diagnostics, `MacroExpansionContext.diagnose` offers the same structured contract with either a string ID or a consumer-owned `RawRepresentable<String>` ID. Empty fragments render a label-specific `[diagnostic authoring defect — empty … fragment]` sentinel so malformed diagnostics stay visible without terminating the compiler plugin.

## Scope and limits

`MacroPluginUtilities` provides:

- declaration queries: `hasModifier`, `hasAttribute`, `attributeNameMatches`, `typeMatches`, `isInstanceVariable`, `existingMemberNames`, `renderEnumCasePattern`, and `enumCaseLabel`;
- property queries: `hasStoredLetProperty`, `unsupportedUninitializedStoredProperties`, `hasConflictingInitializer`, and the `InlineInitializedStoredProperty` projection returned by `inlineInitializedStoredProperty`;
- deterministic fix-its: `makeAddFinalFixIt`, `makeAddMainActorFixIt`, and `makeRemoveInitializerFixIt`;
- `Sendable` utilities: `hasSendableConformance`, `sourceFile(containing:)`, `inheritedTypesContainSendable`, and `sendableExtensionIfNeeded`;
- structured diagnostics: `MacroDiagnosticMessage`, `MacroFixItMessage`, `MacroDiagnosticText.compose`, and both `MacroExpansionContext.diagnose` overloads;
- source locations: `sourceLocationDirective`, a `#sourceLocation` directive that reports errors in generated code on the user's declaration;
- attached-class validation: `MacroAttachedClassRequirements` and its `DiagnosticIDs`, `MacroAttachedClassRequirement`, and `MacroAttachedClassValidator`.

Matching is syntactic. It does not resolve imports, type aliases, overloads, or compiler-known type equivalence. Type matching parses expected type names with `SwiftParser` and compares AST structures directly: removing non-boundary whitespace while preserving spaces between adjacent word tokens (such as `some Error`, `async throws`, and ownership specifiers), normalizing `?` / `Optional<T>` / `Swift.Optional<T>` symmetrically while keeping other module-qualified `Optional` types distinct, unwrapping single-element parentheses and existential `any` where precedence allows (leaving opaque `some` distinct and keeping `(any P).Type` distinct from `any P.Type`), and matching unspecialized module/type qualification, generic arguments (including value generics), tuples, array, dictionary, and inline-array (`[N of T]`) element types, protocol compositions, and metatype bases structurally. `Sendable` extension discovery visits source-file and declaration-group declaration lists, not function, closure, initializer, accessor, or expression bodies. Extensions inside `#if` blocks are not discovered because the active build configuration is unknowable syntactically, so conditionally compiled conformances remain the caller's responsibility.

The package also ships [`swift-source-guardrails`](Documentation/SourceGuardrails.md), a SwiftParser-based executable for repository-owned token bans and counted allowlists. It emits JSON plus human diagnostics and leaves library APIs unchanged. Swift Package Manager resolves the executable's `swift-argument-parser` dependency even for consumers that use only the `MacroPluginUtilities` library.

## Examples

[`Examples/DiagnosticFixItExample`](Examples/DiagnosticFixItExample) is a standalone SwiftPM package that defines `@RequireFinal`, runs an unsigned executable, and verifies diagnostics and fix-it edits with Swift Testing:

```sh
swift test --package-path Examples/DiagnosticFixItExample
swift run --package-path Examples/DiagnosticFixItExample DiagnosticFixItExample
```

## Development

Build the package:

```sh
swift build
```

Run the package tests:

```sh
swift test
```

Run the full test suite, the example package, and repository checks (requires Python 3.11 or later and Ruby with Psych):

```sh
make test
```

Build with complete strict-concurrency checking:

```sh
make build
```

## Platform floor

The package requires macOS 13 or later on the compiler host, supporting throwing output writes in `swift-source-guardrails`. Macro plugins do not execute in downstream app processes, and the manifest does not set an app deployment target.
