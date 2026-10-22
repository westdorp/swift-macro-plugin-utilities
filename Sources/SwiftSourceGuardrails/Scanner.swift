import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

struct GuardrailSource {
    let file: RelativePath
    let text: String
}

enum SourceGuardrails {
    static func scan(configuration: GuardrailConfiguration, files: [GuardrailSource]) throws -> GuardrailReport {
        var matches: [GuardrailReport.Violation] = []
        for file in files.sorted(by: { $0.file.value < $1.file.value }) {
            let rules = configuration.rules.filter { $0.applies(to: file.file) }
            guard !rules.isEmpty else { continue }
            let tree = Parser.parse(source: file.text)
            let locations = SourceLocationConverter(fileName: file.file.value, tree: tree)
            if tree.hasError {
                let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: tree)
                let details = diagnostics.map {
                    let location = locations.location(for: $0.position)
                    return "\(file.file.value):\(location.line):\(location.column): \($0.message)"
                }.joined(separator: "\n")
                throw GuardrailInputError("Cannot scan malformed Swift: \(details)")
            }
            let positions = RuleMatcher.positions(in: tree, matchers: rules.map(\.matcher))
            for (rule, rulePositions) in zip(rules, positions) {
                for position in rulePositions {
                    let location = locations.location(for: position)
                    matches.append(.init(file: file.file.value, line: location.line, column: location.column, rule: rule.id))
                }
            }
        }
        let checks = configuration.allowlist.map { allowance in
            GuardrailReport.AllowlistCheck(
                file: allowance.file.value, rule: allowance.rule, reason: allowance.reason,
                expectedCount: allowance.expectedCount,
                actualCount: matches.filter { $0.file == allowance.file.value && $0.rule == allowance.rule }.count
            )
        }
        let satisfied = Set(checks.filter(\.isSatisfied).map { AllowanceKey(rule: $0.rule, file: $0.file) })
        let violations = matches.filter { !satisfied.contains(AllowanceKey(rule: $0.rule, file: $0.file)) }.sorted {
            ($0.file, $0.line, $0.column, $0.rule) < ($1.file, $1.line, $1.column, $1.rule)
        }
        return GuardrailReport(scannedFiles: files.count, violations: violations, allowlistChecks: checks)
    }
}

