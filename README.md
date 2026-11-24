# swift-macro-plugin-utilities

`swift-macro-plugin-utilities` provides syntactic queries, structured diagnostics, and deterministic fix-its for Swift macro plugins, alongside the [`swift-source-guardrails`](Documentation/SourceGuardrails.md) syntax checker.

## Package stack

This package is the standalone foundation layer of the three-package stack and does not depend on the packages above it:

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

Requires Swift 6.2 or later on macOS 13 or later. Add the package dependency to `Package.swift`:

```swift
.package(url: "https://github.com/westdorp/swift-macro-plugin-utilities.git", .upToNextMinor(from: "0.7.0"))
```

Add `MacroPluginUtilities` to your `.macro` target dependencies:

```swift
.product(name: "MacroPluginUtilities", package: "swift-macro-plugin-utilities")
```

If another dependency already exposes `MacroPluginUtilities`, pass `moduleAliases: ["MacroPluginUtilities": "PluginUtilities"]` on `.product(...)` and write `import PluginUtilities` in your macro target.

Define an attached peer macro, register it in your `CompilerPlugin`, and declare `@RequireFinal` in your library target:

```swift
// RequireFinalMacros target
import MacroPluginUtilities
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

public struct RequireFinalMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        guard let classDecl = declaration.as(ClassDeclSyntax.self),
              !hasModifier(named: "open", in: classDecl.modifiers),
              !hasModifier(named: "final", in: classDecl.modifiers) else { return [] }
        let fixIt = makeAddFinalFixIt(
            for: classDecl,
            fixItMessage: MacroFixItMessage("Add 'final' modifier", domain: "RequireFinalMacro")
        )
        context.diagnose(
            classDecl.name, domain: "RequireFinalMacro", id: "missing-final",
            what: "@RequireFinal requires a final class.",
            why: "Subclasses would bypass the type's invariants.",
            how: "Add the 'final' modifier to this class declaration.",
            fixIts: [fixIt]
        )
        return []
    }
}

@main struct RequireFinalPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [RequireFinalMacro.self]
}

// RequireFinal library target
@attached(peer) public macro RequireFinal() = #externalMacro(module: "RequireFinalMacros", type: "RequireFinalMacro")
```

Attaching `@RequireFinal` to `class Session {}` produces:

```text
error: WHAT: @RequireFinal requires a final class. WHY: Subclasses would bypass the type's invariants. HOW: Add the 'final' modifier to this class declaration.
fix-it: Add 'final' modifier -> final class Session {}
```

To see this live, run `swift test --package-path Examples/DiagnosticFixItExample`, or remove `final` from `Session` in [`Examples/DiagnosticFixItExample/Sources/DiagnosticFixItExample/main.swift`](Examples/DiagnosticFixItExample/Sources/DiagnosticFixItExample/main.swift) and run `swift build --package-path Examples/DiagnosticFixItExample`.

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

Matching is syntactic. It does not resolve imports, type aliases, overloads, or compiler-known type equivalence. Type matching normalizes optional spellings, whitespace, single-element parentheses, qualification, and existential `any`; opaque `some` remains distinct. `Sendable` extension discovery visits source-file and declaration-group declaration lists, not function, closure, initializer, accessor, or expression bodies. Extensions inside `#if` blocks are not discovered because the active build configuration is unknowable syntactically, so conditionally compiled conformances remain the caller's responsibility.

The package also ships [`swift-source-guardrails`](Documentation/SourceGuardrails.md), a SwiftParser-based executable for repository-owned token bans and counted allowlists. It emits JSON plus human diagnostics and leaves library APIs unchanged. Swift Package Manager resolves the executable's `swift-argument-parser` dependency even for consumers that use only the `MacroPluginUtilities` library.

See [MIGRATION.md](MIGRATION.md) for version-specific signature and behavior changes.

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

Run the full test suite, the example package, and repository checks:

```sh
make test
```

Build with complete strict-concurrency checking:

```sh
make build
```

## Platform floor

The package requires macOS 13 or later on the compiler host, supporting throwing output writes in `swift-source-guardrails`. Macro plugins do not execute in downstream app processes, and the manifest does not set an app deployment target.

## Compatibility

Patch releases preserve source compatibility within each minor line. Before `1.0`, a new minor release may include breaking API changes and provides migration notes in [MIGRATION.md](MIGRATION.md).

Before `1.0`, use `.upToNextMinor(from:)` when multiple packages in the same dependency graph depend on this library so they resolve the same minor release.
