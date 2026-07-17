import MacroPluginUtilities
import SwiftDiagnostics
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

    @Test("Compose emits all labels for empty and whitespace-only fragments")
    func composeEmitsAllLabelsForEmptyFragments() {
        let message = MacroDiagnosticText.compose(
            what: "",
            why: " \n\t ",
            how: " "
        )

        #expect(message == "WHAT:  WHY:  HOW: ")
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
            "Invalid declaration",
            domain: "MacroPluginUtilitiesTests",
            id: "invalid-declaration"
        )

        #expect(message.message == "Invalid declaration")
        #expect(
            message.diagnosticID
                == MessageID(
                    domain: "MacroPluginUtilitiesTests",
                    id: "invalid-declaration"
                )
        )
        #expect(message.severity == .error)
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
