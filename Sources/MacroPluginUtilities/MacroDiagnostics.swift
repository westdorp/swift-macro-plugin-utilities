import SwiftDiagnostics

public struct MacroDiagnosticMessage: DiagnosticMessage {
    public let message: String
    public let diagnosticID: MessageID
    public let severity: DiagnosticSeverity = .error

    public init(_ message: String, domain: String, id: String) {
        self.message = message
        self.diagnosticID = MessageID(domain: domain, id: id)
    }
}

public struct MacroFixItMessage: FixItMessage {
    public let message: String
    public let fixItID: MessageID

    public init(_ message: String, domain: String) {
        self.message = message
        self.fixItID = MessageID(domain: domain, id: message)
    }
}

/// Renders the macro diagnostics contract: every message states WHAT is wrong,
/// WHY it matters, and HOW to fix it, as literally labeled sentences.
public enum MacroDiagnosticText {
    /// Composes `"WHAT: … WHY: … HOW: …"` from whitespace-normalized fragments.
    ///
    /// Every label is always emitted, so a diagnostic can never silently
    /// shed part of the contract.
    public static func compose(
        what: String,
        why: String,
        how: String
    ) -> String {
        [
            labeled("WHAT", what),
            labeled("WHY", why),
            labeled("HOW", how),
        ]
        .joined(separator: " ")
    }

    private static func labeled(_ label: String, _ fragment: String) -> String {
        let normalized = fragment
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return "\(label): \(normalized)"
    }
}
