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

Downstream adoption is separate: this product does not replace this package's
existing test guardrail script or any consuming repository's gate.
