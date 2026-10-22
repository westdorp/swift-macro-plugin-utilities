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
}
