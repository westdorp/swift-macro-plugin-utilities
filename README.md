# swift-macro-plugin-utilities

`MacroPluginUtilities` provides focused syntactic queries, diagnostics, and
deterministic fix-its for Swift macro-plugin implementations. It is not a macro
framework, semantic type checker, or runtime library.

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

- exact modifier and attribute queries;
- normalized syntactic type matching;
- stored-property and initializer queries;
- deterministic `final` and `@MainActor` fix-its;
- direct and visible-extension `Sendable` discovery.

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

Build with complete strict-concurrency checking using:

```sh
make build
```

## Platform floor

The manifest declares macOS 10.15, matching SwiftSyntax 602's dependency
floor. This is a compiler-host build constraint: macro plugins do not execute
in downstream app processes, and the declaration does not set an app deployment
target. The `0.1.0` package gate verifies this host configuration on macOS 26.

## Provenance

This repository is the canonical, living home of utilities originally frozen
from the PlaybackStateMachineMacros package at revision
`214443b8fb0d1ab228ab8b79d6c17d4f3497a7b6`. The frozen revision records the
extraction origin; development continues here.

## Compatibility

The `0.1.x` patch line preserves source compatibility. Before `1.0`, a minor
release such as `0.2.0` may include breaking API changes and will provide
migration notes.
