struct GuardrailReport: Encodable {
    struct Violation: Encodable {
        let file: String
        let line: Int
        let column: Int
        let rule: String
    }

    struct AllowlistCheck: Encodable {
        let file: String
        let rule: String
        let reason: String
        let expectedCount: Int
        let actualCount: Int
        var isSatisfied: Bool { expectedCount == actualCount }
    }

    let schemaVersion = 1
    var scannedFiles = 0
    var violations: [Violation] = []
    var allowlistChecks: [AllowlistCheck] = []
    var errors: [String] = []

    var exitCode: Int32 {
        if !errors.isEmpty { return 2 }
        return violations.isEmpty && allowlistChecks.allSatisfy(\.isSatisfied) ? 0 : 1
    }

    var humanSummary: String {
        var lines = violations.map { "\($0.file):\($0.line):\($0.column): \($0.rule)" }
        lines += allowlistChecks.filter { !$0.isSatisfied }.map {
            "\($0.file): \($0.rule) allowlist expected \($0.expectedCount), found \($0.actualCount) (\($0.reason))"
        }
        lines += errors.map { "error: \($0)" }
        switch exitCode {
        case 0: lines.append("Swift source guardrails passed (\(scannedFiles) file(s)).")
        case 1: lines.append("Swift source guardrails failed: \(violations.count) violation(s), \(allowlistChecks.filter { !$0.isSatisfied }.count) allowlist mismatch(es).")
        default: lines.append("Swift source guardrails failed: input error; scan incomplete.")
        }
        return lines.joined(separator: "\n")
    }
}
