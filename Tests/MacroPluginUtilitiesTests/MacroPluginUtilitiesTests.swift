import MacroPluginUtilities
import Testing

@Suite("Macro Diagnostic Text")
struct MacroPluginUtilitiesTests {
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
}
