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

Existing class calls remain unchanged. Struct consumers delete private duplicate
logic and call:

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
- Type normalization deliberately removes existential `any` while preserving
  opaque `some`; this behavior is unchanged and is now documented.
- No public symbol is removed or renamed.

## Package platform floor

`0.1.0` declares macOS 10.15, matching SwiftSyntax 602's dependency floor and
preventing SwiftPM from selecting an older implicit root-package default. This
constraint describes the compiler host build; it does not make the utilities
runtime code or set downstream app deployment targets.

## Downstream ownership changes

NetworkExtensionMacros B4 should delete
`ProviderConfigurationMacro+GenerationSendable.swift`'s private
traversal/query implementation and call the package function with its
`StructDeclSyntax`.

PlaybackStateMachineMacros consumers keep their existing direct class calls and
remove ownership of the vendored sources when they adopt the package.
