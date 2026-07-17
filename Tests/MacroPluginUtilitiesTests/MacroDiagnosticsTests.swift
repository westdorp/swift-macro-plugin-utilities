import MacroPluginUtilities
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@Suite("Macro diagnostics")
struct MacroDiagnosticsTests {
    @Test("Compose labels segments in WHAT-WHY-HOW order")
    func composeLabelsSegmentsInContractOrder() {
        let message = MacroDiagnosticText.compose(
            what: "State enum is required.",
            why: "The state machine needs a finite state domain.",
            how: "Add nested enum State { ... }."
        )

        #expect(
            message == "WHAT: State enum is required. WHY: The state machine needs a finite state domain. HOW: Add nested enum State { ... }."
        )
    }

    @Test("Compose normalizes whitespace inside each fragment")
    func composeNormalizesWhitespaceInsideFragments() {
        let message = MacroDiagnosticText.compose(
            what: "Event  marker\nis missing.",
            why: "Event role metadata\tis derived from enum cases.",
            how: "\nAdd @PlaybackInput.\n"
        )

        #expect(
            message == "WHAT: Event marker is missing. WHY: Event role metadata is derived from enum cases. HOW: Add @PlaybackInput."
        )
    }

    @Test(
        "Compose makes empty fragments visible",
        arguments: [
            (
                "", "Reason.", "Action.",
                "WHAT: [diagnostic authoring defect — empty WHAT fragment] WHY: Reason. HOW: Action."
            ),
            (
                "State is missing.", " \n\t ", "Action.",
                "WHAT: State is missing. WHY: [diagnostic authoring defect — empty WHY fragment] HOW: Action."
            ),
            (
                "State is missing.", "Reason.", "",
                "WHAT: State is missing. WHY: Reason. HOW: [diagnostic authoring defect — empty HOW fragment]"
            ),
        ]
    )
    func composeMakesEmptyFragmentsVisible(
        what: String,
        why: String,
        how: String,
        expected: String
    ) {
        let message = MacroDiagnosticText.compose(
            what: what,
            why: why,
            how: how
        )

        #expect(message == expected)
    }

    @Test("Compose normalizes hostile content without interpreting it")
    func composeNormalizesHostileContent() {
        let message = MacroDiagnosticText.compose(
            what: "`value` != value; WHY: decoy",
            why: "#identifier\tcontains punctuation?!",
            how: "Use @Module.Attribute(name: \"x y\")."
        )

        #expect(
            message == "WHAT: `value` != value; WHY: decoy WHY: #identifier contains punctuation?! HOW: Use @Module.Attribute(name: \"x y\")."
        )
    }

    @Test("Diagnostic message preserves its public contract")
    func diagnosticMessagePreservesContract() {
        let message = MacroDiagnosticMessage(
            domain: "MacroPluginUtilitiesTests",
            id: "invalid-declaration",
            what: "Invalid declaration.",
            why: "The macro requires a class.",
            how: "Attach the macro to a class.",
            severity: .warning
        )

        #expect(
            message.message
                == "WHAT: Invalid declaration. WHY: The macro requires a class. HOW: Attach the macro to a class."
        )
        #expect(
            message.diagnosticID
                == MessageID(
                    domain: "MacroPluginUtilitiesTests",
                    id: "invalid-declaration"
                )
        )
        #expect(message.severity == .warning)
    }

    @Test("Low-level and convenience diagnostics preserve identity, text, and fix-its")
    func diagnosticEntryPointsPreserveContract() {
        let context = BasicMacroExpansionContext(lexicalContext: [])
        let node = TokenSyntax.identifier("Target")
        let replacement = TokenSyntax.identifier("Replacement")
        let fixIt = FixIt(
            message: MacroFixItMessage("Replace target", domain: "Tests"),
            changes: [
                .replace(oldNode: Syntax(node), newNode: Syntax(replacement))
            ]
        )
        let lowLevelMessage = MacroDiagnosticMessage(
            domain: "Tests",
            id: FixtureDiagnosticID.invalidDeclaration.rawValue,
            what: "Invalid declaration.",
            why: "The macro requires a class.",
            how: "Attach the macro to a class.",
            severity: .error
        )

        context.diagnose(
            Diagnostic(node: node, message: lowLevelMessage, fixIts: [fixIt])
        )
        context.diagnose(
            node,
            domain: "Tests",
            id: FixtureDiagnosticID.invalidDeclaration.rawValue,
            what: "Invalid declaration.",
            why: "The macro requires a class.",
            how: "Attach the macro to a class.",
            fixIts: [fixIt]
        )
        context.diagnose(
            node,
            domain: "Tests",
            id: FixtureDiagnosticID.invalidDeclaration,
            what: "Invalid declaration.",
            why: "The macro requires a class.",
            how: "Attach the macro to a class.",
            fixIts: [fixIt]
        )

        let expectedID = MessageID(domain: "Tests", id: "invalid-declaration")
        let expectedText = "WHAT: Invalid declaration. WHY: The macro requires a class. HOW: Attach the macro to a class."
        #expect(context.diagnostics.count == 3)
        #expect(
            context.diagnostics.map(\.diagnosticID)
                == Array(repeating: expectedID, count: 3)
        )
        #expect(
            context.diagnostics.map(\.message)
                == Array(repeating: expectedText, count: 3)
        )
        #expect(context.diagnostics.allSatisfy { $0.fixIts.count == 1 })
        #expect(
            context.diagnostics.map { $0.fixIts[0].message.fixItID }
                == Array(
                    repeating: MessageID(domain: "Tests", id: "Replace target"),
                    count: 3
                )
        )
    }

    @Test("Fix-it message derives its ID from the supplied message")
    func fixItMessageDerivesIdentifierFromMessage() {
        let message = MacroFixItMessage(
            "Add `final`!",
            domain: "MacroPluginUtilitiesTests"
        )

        #expect(message.message == "Add `final`!")
        #expect(
            message.fixItID
                == MessageID(
                    domain: "MacroPluginUtilitiesTests",
                    id: "Add `final`!"
                )
        )
    }
}

private enum FixtureDiagnosticID: String {
    case invalidDeclaration = "invalid-declaration"
}
