import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// A structured diagnostic with caller-defined identity and severity.
public struct MacroDiagnosticMessage: DiagnosticMessage {
    public let message: String
    public let diagnosticID: MessageID
    public let severity: DiagnosticSeverity

    /// Creates a diagnostic that always renders WHAT, WHY, and HOW.
    public init(
        domain: String,
        id: String,
        what: String,
        why: String,
        how: String,
        severity: DiagnosticSeverity
    ) {
        self.message = MacroDiagnosticText.compose(what: what, why: why, how: how)
        self.diagnosticID = MessageID(domain: domain, id: id)
        self.severity = severity
    }
}

extension MacroExpansionContext {
    /// Diagnoses an error with a consumer-owned typed identifier.
    public func diagnose<ID: RawRepresentable>(
        _ node: some SyntaxProtocol,
        domain: String,
        id: ID,
        what: String,
        why: String,
        how: String,
        fixIts: [FixIt] = []
    ) where ID.RawValue == String {
        diagnose(
            node,
            domain: domain,
            id: id.rawValue,
            what: what,
            why: why,
            how: how,
            fixIts: fixIts
        )
    }

    /// Diagnoses an error with structured text and a stable string identifier.
    public func diagnose(
        _ node: some SyntaxProtocol,
        domain: String,
        id: String,
        what: String,
        why: String,
        how: String,
        fixIts: [FixIt] = []
    ) {
        diagnose(
            Diagnostic(
                node: node,
                message: MacroDiagnosticMessage(
                    domain: domain,
                    id: id,
                    what: what,
                    why: why,
                    how: how,
                    severity: .error
                ),
                fixIts: fixIts
            )
        )
    }
}

/// A fix-it message identified by its domain and display text.
public struct MacroFixItMessage: FixItMessage {
    public let message: String
    public let fixItID: MessageID

    /// Creates a fix-it message whose text is its identifier.
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
    /// Empty fragments render an authoring-defect sentinel, so every label has
    /// visible content without terminating the compiler plugin process.
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
        let visibleFragment = normalized.isEmpty
            ? "[diagnostic authoring defect — empty \(label) fragment]"
            : normalized
        let rendered = "\(label): \(visibleFragment)"

        assert(!visibleFragment.isEmpty, "Diagnostic labels must render visible content.")
        return rendered
    }
}
