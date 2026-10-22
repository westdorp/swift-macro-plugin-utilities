# swift-macro-plugin-utilities

`MacroPluginUtilities` provides focused syntactic queries, diagnostics, and
deterministic fix-its for Swift macro-plugin implementations. It is not a macro
framework, semantic type checker, or runtime library.

The package also ships [`swift-source-guardrails`](Documentation/SourceGuardrails.md),
a SwiftParser-based executable for repository-owned token bans and counted
allowlists. It emits JSON plus human diagnostics and leaves library APIs unchanged.
Swift Package Manager resolves the executable's `swift-argument-parser`
dependency even for consumers that use only the `MacroPluginUtilities` library.

## Diagnostic contract

Macro diagnostics must say what is wrong, why it matters, and how to fix it.
`MacroDiagnosticMessage` accepts those fragments directly, preserves a stable
caller-defined identity and severity, and normalizes whitespace without
interpreting diagnostic content:

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

The result is:

```text
WHAT: State enum is missing. WHY: The macro needs a finite state domain. HOW: Add a nested State enum.
```

For error diagnostics, `MacroExpansionContext.diagnose` offers the same
structured contract with either a string ID or a consumer-owned
`RawRepresentable<String>` ID. Empty fragments render a label-specific
`[diagnostic authoring defect — empty … fragment]` sentinel so malformed
diagnostics remain visible without terminating the compiler plugin.

## Scope and limits

The package provides:

- declaration queries: `hasModifier`, `hasAttribute`,
  `attributeNameMatches`, `typeMatches`, `isInstanceVariable`,
  `existingMemberNames`, `renderEnumCasePattern`, and `enumCaseLabel`;
- property queries: `hasStoredLetProperty`,
  `unsupportedUninitializedStoredProperties`, `hasConflictingInitializer`,
  and the `InlineInitializedStoredProperty` projection returned by
  `inlineInitializedStoredProperty`;
- deterministic fix-its: `makeAddFinalFixIt`, `makeAddMainActorFixIt`, and
  `makeRemoveInitializerFixIt`;
- `Sendable` utilities: `hasSendableConformance`, `sourceFile(containing:)`,
  `inheritedTypesContainSendable`, and `sendableExtensionIfNeeded`;
- structured diagnostics: `MacroDiagnosticMessage`, `MacroFixItMessage`,
  `MacroDiagnosticText.compose`, and both `MacroExpansionContext.diagnose`
  overloads;
- source locations: `sourceLocationDirective`, a `#sourceLocation` directive
  that reports errors in generated code on the user's declaration;
- attached-class validation: `MacroAttachedClassRequirements` and its
  `DiagnosticIDs`, `MacroAttachedClassRequirement`, and
  `MacroAttachedClassValidator`.

Matching is intentionally syntactic. It does not resolve imports, type aliases,
overloads, or compiler-known type equivalence. Type matching normalizes optional
spellings, whitespace, single-element parentheses, qualification, and
existential `any`; opaque `some` remains distinct. `Sendable` extension
discovery visits source-file and declaration-group declaration lists, not
function, closure, initializer, accessor, or expression bodies. Extensions
inside `#if` blocks are not discovered: the active build configuration is
unknowable syntactically, so conditionally compiled conformances stay the
caller's responsibility.

See [MIGRATION.md](MIGRATION.md) for version-specific signature and behavior
changes.

## Development

Run the complete package gate with:

```sh
make test
```

The gate includes `make test-dependency-owners`, which fails when a non-test
target reaches a package outside `swiftlang`, `apple`, and `westdorp`;
test-only packages are exempt. The docstring of
`Scripts/check-dependency-owners.py` explains why.

Build with complete strict-concurrency checking using:

```sh
make build
```

## Platform floor

The package requires macOS 13 or later on the compiler host, matching its
macOS 13-or-later consumers and supporting throwing output writes in
`swift-source-guardrails`. Macro plugins do not execute
in downstream app processes, and the declaration does not set an app deployment
target. The package gate verifies this host configuration on macOS 26.

## Provenance

This repository is the canonical, living home of utilities originally frozen
from the `PlaybackStateMachineMacros` package in the
`swift-playback-machine-macros-private` repository at revision
`214443b8fb0d1ab228ab8b79d6c17d4f3497a7b6`. The frozen revision records the
extraction origin; development continues here.

## Compatibility

Patch releases preserve source compatibility within each minor line. Before
`1.0`, a new minor release may include breaking API changes and will provide
migration notes.

Policy for westdorp packages that use these utilities: require them with
`.upToNextMinor(from:)` on the same minor, so they admit the same release and
cannot conflict with each other, and move them together on each new minor. At
`1.0` they move to `from:`.
