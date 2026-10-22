# Swift source guardrails

`swift-source-guardrails` checks repository-owned policies using SwiftParser and
SwiftSyntax from the package's existing swift-syntax dependency. ArgumentParser
parses command arguments; Foundation's Codable JSON decoder reads configuration.
It reads source and configuration without modifying either.

```sh
swift run swift-source-guardrails --config guardrails.json --root . > guardrails-report.json
```

`--config` is required. `--root` defaults to the working directory. Both arguments
are filesystem paths relative to the working directory when not absolute.
`--help` describes the arguments. A compiled executable can be run directly.

## Configuration version 1

All fields shown below are required. Unknown fields, unsupported versions, wrong
JSON types and invalid values are input errors. Paths use `/`, are relative to
`--root`, and name a directory or a single `.swift` file. Absolute paths, empty
components, `.`, `..`, backslashes and control characters are rejected. Paths
are literal: no glob, regular expression or exclusion syntax is supported.

```json
{
  "version": 1,
  "rules": [
    {
      "id": "no-task-sleep",
      "tokens": ["Task", ".", "sleep"],
      "paths": ["Sources", "Tests"]
    },
    {
      "id": "inject-test-clock",
      "tokens": ["ContinuousClock", "(", ")"],
      "paths": ["Tests"]
    }
  ],
  "allowlist": [
    {
      "rule": "inject-test-clock",
      "file": "Tests/AdapterTests.swift",
      "reason": "Production clock adapter wiring fixture",
      "expectedCount": 1
    }
  ]
}
```

`rules` must be nonempty. Every rule has a unique, nonblank `id`, a nonempty
`tokens` array and nonempty `paths`. Each token string must be one Swift code token
without surrounding trivia. String-literal and regex-literal token kinds are
rejected, including their delimiters and contents. For example, `Task.sleep` is three tokens and must
be written as `["Task", ".", "sleep"]`. Tokens match consecutively in code,
ignoring whitespace and comments. Identifier backticks are normalized. Longer
identifiers such as `OtherTask` or `sleeper` do not match those token strings.
Multiple rules can report the same location. Overlapping scopes scan each file
once. A directory covers descendants at component boundaries: `Tests` does not
cover `TestsOther`.

`allowlist` is required and may be empty. An entry names an existing rule and a
`.swift` file within that rule's scope, a nonblank `reason`, and a positive
integer `expectedCount`. A `(rule, file)` pair may appear only once. The count is
the number of token-sequence starts in that file, including overlapping matches.
Only an exact count suppresses those matches. Too few, too many, a removed file
or a now-unused allowance fails the check. Other files remain subject to the
rule. A count mismatch reports the actual count and leaves matches visible.

## Configuration version 2

Version 1 remains supported with identical matching and output. Version 2 uses
tagged `match` objects and can share literal path lists through named scope sets:

```json
{
  "version": 2,
  "scopes": {"production": ["Sources"]},
  "rules": [
    {
      "id": "clock-names",
      "scope": "production",
      "match": {"kind": "identifier", "target": "token",
                "pattern": {"kind": "suffix", "text": "Clock"}}
    }
  ],
  "allowlist": []
}
```

Every rule requires `id`, `match`, and exactly one of `paths` or `scope`.
`scopes` is optional; each named set has a nonblank name and nonempty path list.
Scope references must exist. Rules resolve their scope before normal recursive
file discovery, so a new file under `Sources` is automatically covered. Unused
sets are validated as paths but are not discovered. Existing path and allowance
validation applies unchanged. Unknown fields and incompatible fields fail closed.

`{"kind":"tokens","tokens":["Task",".","sleep"]}` retains v1 token semantics.
`identifier` requires `target` (`token` or `function`) and a `pattern` with
`kind` (`prefix` or `suffix`) and `text` (one Swift identifier). These compare
literal identifier spelling, normalizing backticks; they have no wildcard or
regular expression syntax. `token` includes identifier declarations and uses;
`function` checks only function declaration names. Comments, string text and
regex contents do not count. Multiline declarations are handled by SwiftSyntax.

To migrate a v1 rule, move its `tokens` array into a `match` object of kind
`tokens`, keep `id` and `paths`, and change the configuration version to `2`.
Then replace repeated `paths` arrays with a named `scope` where useful.
The allowlist and output schema do not change.

### Calls, members, contexts and argument values

`{"kind":"call","name":["Task","sleep"]}` matches a
`FunctionCallExprSyntax` with that spelled callee.
`{"kind":"member","name":["Task","sleep"]}` also matches member references
without a call. Generic specializations on any component are ignored:
`Task<Result<Int, Error>, Never>.sleep(...)` matches both. Balanced generic and
argument groups, comments, trailing closures and multiline forms are handled by
SwiftParser. A call to `Task<...> { ... }` has name `["Task"]`;
`Thread.init(...)` has name `["Thread","init"]`. Names are nonempty component
arrays, with backticks normalized. They match exactly: `Swift.Task.sleep` needs
`["Swift","Task","sleep"]`. A single-component name matches a free name or an
implicit member such as `.sleep()`. These rules do not resolve aliases or types,
unwrap optional chaining, or search arbitrary expressions for a name.

An occurrence rule may add a sibling `context`:

```json
"context": {"relation":"outside", "kind":"type", "name":"ClockAdapter"}
```

`relation` is `inside` or `outside`; `kind` is `type` or `function`. A match is
inside when its token has an enclosing declaration with that name. Types include
structs, classes, actors, enums, protocols and extensions; extensions use the
final type component. Function overloads share a name. Nested types, nested
functions and closures retain their enclosing context. `outside` is the
complement, including top-level code. Context names are single Swift names.
The same filter works with token and identifier rules.

`{"kind":"argument","call":["schedule"],"label":"minutes",`
`"validation":"positiveIntegerLiteral"}` checks each matching call for exactly
one argument with that label. Missing, repeated and invalid values report once
at the call. `positiveIntegerLiteral` requires a positive `IntegerLiteralExprSyntax`
whose SwiftSyntax `representedLiteralValue` fits `Int`; decimal, binary, octal,
hexadecimal and separators are supported. Expressions, signed prefixes,
parentheses, variables, floats, zero and overflow fail. `nonemptyStringLiteral`
requires a noninterpolated string literal with a nonblank decoded value, suitable
for a named `reason` argument. Neither validator evaluates expressions.

## Swift classification and limits

SwiftParser determines code, comments, normal/escaped/raw/multiline strings, and
bare/extended/multiline regex literals. Literal contents and comments do not
match. Executable expressions inside string interpolation do match, including
raw-string interpolation, nested strings and closures. Token matching cannot
cross a literal or interpolation boundary. A regex inside an interpolation is
still a regex literal and does not match.

Matching is syntactic. It does not resolve names, imports, aliases, overloads or
types, and does not expand macros. A qualified spelling `Swift.Task.sleep` still
contains the sequence `Task`, `.`, `sleep`; an alias spelling does not. All
conditional compilation branches are checked. The `#if`, `#elseif`, `#else` and
`#endif` directive keyword tokens are omitted from match runs. Each `#if` and
`#elseif` condition is checked as a separate code run: `["canImport", "(", "X", ")"]`
matches `#if canImport(X)`, and `["DEBUG"]` matches `#if DEBUG`. A condition cannot
join tokens before or after it, including tokens in another condition. Clause
bodies are visited in source order without interrupting the surrounding code run. Thus
`Task` followed by `#if A`, `.sleep()` and `#endif` is reported. Matching can
also span mutually exclusive clause bodies; it does not evaluate conditions.
The sequence `["A", ".", "sleep"]` does not join `#if A` to a following `.sleep()`.
The installed/resolved
swift-syntax version defines accepted Swift grammar, which may differ from a
newer compiler. SwiftParser parse errors fail closed rather than accepting a
partial parse; this is not a substitute for compiler type checking.

Discovery includes hidden files and directories, and reads only `.swift` files
in the configured scopes. Each scope must exist and contain at least one Swift
file, even when another scope overlaps it. Unreadable files/directories, invalid
UTF-8, malformed Swift and special filesystem entries fail closed. Symbolic
links within a selected scope or along its relative path are rejected, including
directory links and broken links. `--root` itself is resolved to its canonical
directory. Source trees must remain stable during the scan; discovery and reads
do not provide a filesystem snapshot.

## Output and exit status

After argument parsing, stdout contains one JSON object with these fields:

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Output schema version, currently `1` |
| `scannedFiles` | Number of unique input files in a completed scan |
| `violations` | Unsuppressed matches: `file`, `line`, `column`, `rule` |
| `allowlistChecks` | Every allowance: `file`, `rule`, `reason`, `expectedCount`, `actualCount` |
| `errors` | Input error messages; a nonempty array means the scan was incomplete |

Locations are physical file locations, unaffected by `#sourceLocation`. Lines
and UTF-8 byte columns start at 1. Paths are relative to the source root.
Violations sort by file, line, column, then rule. Allowlist checks retain config
order. Input errors return an incomplete
report with `scannedFiles: 0`, no partial violations and an `errors` entry.

Stderr contains per-violation locations, count mismatches and a human summary.
Exit `0` means the scan completed and all policies/counts passed; `1` means a
ban or allowlist count failed; `2` means an input error. ArgumentParser owns help
and usage errors: `--help` prints help with exit `0`, and invalid/missing
arguments print a usage diagnostic with exit `64`, without a JSON report.
Output write failures throw to ArgumentParser, which reports an error with exit
`1`. A failed write can leave stdout or stderr incomplete; a scan's normal exit
status applies only after both writes succeed, so a write failure exits `1`
even when the scan found an input error that would otherwise exit `2`.

Downstream adoption is separate: this product does not replace this package's
existing test guardrail script or any consuming repository's gate.
