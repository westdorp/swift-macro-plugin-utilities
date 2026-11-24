# Unreleased

## Type matching and attached-class validation updates

### Type matching

- `typeMatches` (and its callers `hasStoredLetProperty` and
  `hasConflictingInitializer`) now preserves a separating space between adjacent
  word tokens instead of stripping all whitespace. Expected strings for
  multi-word spellings must include that space (for example `()async throws->Void`,
  `inout Foo`, `borrowing Foo`, `consuming Foo`, `sending Foo`, and `some Foo`).
- Qualification matching is now structural rather than a raw string suffix
  check. Specialized enclosing segments such as `Outer<Int>.Item` no longer
  match `Item`, and metatype suffixes such as `Swift.Int.Type` /
  `Swift.Int.Protocol` no longer match bare `Type` / `Protocol`.
- Optional and implicitly unwrapped optional wrappers of non-postfix-atomic
  types (function types, protocol compositions, and opaque `some` types) now
  preserve grouping parentheses rather than unwrapping them. Expected strings
  using `?` or `!` sugar must retain those parentheses (for example
  `(()->Void)?` and `(Equatable&Sendable)?` instead of `()->Void?` and
  `Equatable&Sendable?`).
- Optional spellings (`T?`, `Optional<T>`, and `Swift.Optional<T>`) now match
  symmetrically in both directions, while other module-qualified types named
  `Optional` (such as `MyModule.Optional<Int>` and
  `Namespace.Swift.Optional<Int>`) no longer match unqualified `Optional<Int>`,
  `Swift.Optional<Int>`, or `Int?`.
- Qualified protocol compositions (`any Swift.Equatable & Swift.Sendable`),
  array and dictionary element types (`[Swift.Int]`, `[Swift.String: Swift.Int?]`),
  parenthesized metatype bases (`(Swift.Int).Type`, `(any Swift.Error).Type`),
  and Swift 6.2 value generic arguments (`Swift.InlineArray<4, Swift.Int>`) now
  match structurally.

### Attached-class final validation

- `MacroAttachedClassValidator.satisfies(.finalClass)` now rejects classes
  marked both `open` and `final`.
- `MacroAttachedClassValidator.validate(.finalClass, in:)` now withholds the
  automatic `Add 'final' modifier` fix-it for `open` classes, classes with
  `open` members, and classes containing nested or local class declarations, and
  updates its fixable `HOW` guidance to remind callers to confirm no external
  subclasses exist before adding `final`.

---

# Migrating to 0.2.0

## `0.1.0` adopters

### Use structured diagnostics

`MacroDiagnosticMessage` no longer accepts arbitrary message text.

Before:

```swift
MacroDiagnosticMessage(
    MacroDiagnosticText.compose(what: what, why: why, how: how),
    domain: domain,
    id: id
)
```

After:

```swift
MacroDiagnosticMessage(
    domain: domain,
    id: id,
    what: what,
    why: why,
    how: how,
    severity: .error
)
```

For error emission, prefer the context convenience:

```swift
context.diagnose(
    node,
    domain: domain,
    id: id,
    what: what,
    why: why,
    how: how,
    fixIts: fixIts
)
```

Rewrite arbitrary raw messages into meaningful WHAT, WHY, and HOW fragments.
Warning and note callers use the structured initializer because the convenience
deliberately emits errors.

### Supply visible diagnostic fragments

Empty and whitespace-only fragments formerly rendered blank content such as
`WHAT:  WHY: reason HOW: `. They now render a label-specific
`[diagnostic authoring defect — empty … fragment]` sentinel. Supply nonempty
fragments and update exact diagnostic snapshots; the sentinel is fallback
visibility, not an endorsed authoring path.

All other `0.1.0` APIs remain source-compatible; the remaining `0.2.0`
utilities are additive.

## Vendored-module users

### Adopt the canonical package

Add the exact package dependency:

```swift
.package(
    url: "https://github.com/westdorp/swift-macro-plugin-utilities.git",
    exact: "0.2.0"
)
```

Add the `MacroPluginUtilities` product to each consuming macro target. Delete
the local utility target, its vendored source files, and its utility test
target only after their unique tests are present upstream.

### Remove optional fix-it adaptation

Replace:

```swift
[makeAddFinalFixIt(...)].compactMap { $0 }
```

with:

```swift
[makeAddFinalFixIt(...)]
```

Apply the same rewrite to `makeAddMainActorFixIt`.

### Keep diagnostic IDs consumer-owned

Preserve consumer-owned typed diagnostic enums and pass their cases directly
to the generic context convenience. Do not move consumer-specific ID cases
into `MacroPluginUtilities`.

### Account for inherited behavior changes

- Stored-let types use full normalization.
- Detached and nested `Sendable` lookup uses lexical qualification.
- Extensions inside executable bodies and `#if` blocks are excluded.
- Class call sites remain source-compatible with the generalized
  declaration-group parameter.

### Remove redundant diagnostic emitters

Delete any now-identical local diagnostic emitter or helper once direct context
calls preserve its domain, ID, WHAT/WHY/HOW fragments, and fix-its.

# Migrating to 0.1.0

`0.1.0` establishes `swift-macro-plugin-utilities` as the canonical package
for the formerly frozen utility sources.

## Signature changes

### `makeAddFinalFixIt`

Frozen: `makeAddFinalFixIt(...) -> FixIt?`

`0.1.0`: `makeAddFinalFixIt(...) -> FixIt`

Replace optional collection adaptation:

Before: `[makeAddFinalFixIt(...)].compactMap { $0 }`

After: `[makeAddFinalFixIt(...)]`

Replace optional binding or `.map { [$0] } ?? []` with a direct binding or
singleton array. Passing the concrete result to a `FixIt?` parameter remains
valid through optional promotion.

### `makeAddMainActorFixIt`

Frozen: `makeAddMainActorFixIt(...) -> FixIt?`

`0.1.0`: `makeAddMainActorFixIt(...) -> FixIt`

Apply the same mechanical rewrite: remove optional binding, `compactMap`, and
optional-to-array adaptation.

### `hasSendableConformance`

Frozen:

```swift
hasSendableConformance(
    in: ClassDeclSyntax,
    lexicalContext: [Syntax] = []
) -> Bool
```

`0.1.0`:

```swift
hasSendableConformance(
    in: some DeclGroupSyntax,
    lexicalContext: [Syntax] = []
) -> Bool
```

Existing class calls remain unchanged. Struct consumers whose private lookup
matches the same unconditional declaration-list traversal (see
[Behavior changes without call-site rewrites](#behavior-changes-without-call-site-rewrites)
for the `#if` limitation) can delete that duplicate logic and call:

```swift
hasSendableConformance(
    in: structDecl,
    lexicalContext: lexicalContext
)
```

Replace any explicitly stored class-only function reference with a forwarding
generic function.

## Behavior changes without call-site rewrites

- `hasStoredLetProperty` now uses `typeMatches`, accepting the same qualified,
  optional, parenthesized, whitespace-normalized, and existential spellings.
- `hasSendableConformance` reconstructs detached declaration qualification from
  lexical context, compares complete qualified components, and ignores extension
  declarations hidden in executable bodies.
- `hasSendableConformance` no longer discovers extensions inside `#if` blocks
  (the frozen implementation's unrestricted traversal did). The active build
  configuration is unknowable syntactically; conditionally compiled
  conformances remain the caller's responsibility.
- Type normalization deliberately removes existential `any` while preserving
  opaque `some`; this behavior is unchanged and is now documented.
- No public symbol is removed or renamed.

## Package platform floor

`0.1.0` declares macOS 10.15, matching SwiftSyntax 602's dependency floor and
preventing SwiftPM from selecting an older implicit root-package default. This
constraint describes the compiler host build; it does not make the utilities
runtime code or set downstream app deployment targets.

## Downstream ownership changes

Struct macro consumers whose private `Sendable` lookup matches the same
unconditional declaration-list traversal can delete that private implementation
and call `hasSendableConformance(in:lexicalContext:)` directly with their
`StructDeclSyntax`. Consumers that rely on discovering conformances declared
inside `#if` blocks must handle conditional compilation explicitly, as noted in
[Behavior changes without call-site rewrites](#behavior-changes-without-call-site-rewrites).

Class macro consumers keep their existing direct class calls and remove
ownership of any vendored utility sources when they adopt the package.
