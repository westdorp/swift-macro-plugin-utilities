import MacroPluginUtilities
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@Suite("Macro attached-class validation")
struct MacroAttachedClassValidationTests {
    @Test("Accepts the complete attached class contract")
    func acceptsCompleteContract() throws {
        let validator = MacroAttachedClassValidator(
            classDeclaration: try parseClass(
                """
                @MainActor
                final class Monitor {
                    let player: AVPlayer
                }
                """
            ),
            requirements: observerRequirements
        )

        #expect(
            validator.satisfies([
                .finalClass,
                .mainActorIsolation,
                .storedLetProperty,
                .initializerAvailability,
            ])
        )
    }

    @Test(
        "Rejects and diagnoses each missing attached-class requirement",
        arguments: [
            MissingRequirement(
                source: "@MainActor class Monitor { let player: AVPlayer }",
                requirement: .finalClass,
                id: "class-only",
                message: "WHAT: @Observer can only be applied to a final class. WHY: Lifecycle state requires stable identity. HOW: Add the 'final' modifier to this class declaration.",
                fixItMessages: ["Add 'final' modifier"]
            ),
            MissingRequirement(
                source: "final class Monitor { let player: AVPlayer }",
                requirement: .mainActorIsolation,
                id: "mainactor-required",
                message: "WHAT: @Observer requires @MainActor isolation. WHY: Callbacks mutate actor-owned state. HOW: Annotate the type with '@MainActor'.",
                fixItMessages: ["Add '@MainActor' attribute"]
            ),
            MissingRequirement(
                source: "@MainActor final class Monitor { var player: AVPlayer }",
                requirement: .storedLetProperty,
                id: "player-required",
                message: "WHAT: @Observer requires a stored instance property 'let player: AVPlayer'. WHY: Observation reads the player. HOW: Add 'let player: AVPlayer'.",
                fixItMessages: []
            ),
            MissingRequirement(
                source: "@MainActor final class Monitor { let player: AVPlayer; init(player: AVPlayer) { self.player = player } }",
                requirement: .initializerAvailability,
                id: "init-conflict",
                message: "WHAT: @Observer cannot synthesize 'init(player:)' because it is already declared. WHY: The macro owns initialization. HOW: Remove the custom 'init(player:)' or remove @Observer and manage wiring manually.",
                fixItMessages: []
            ),
        ]
    )
    func rejectsMissingRequirement(testCase: MissingRequirement) throws {
        let validator = MacroAttachedClassValidator(
            classDeclaration: try parseClass(testCase.source),
            requirements: observerRequirements
        )
        let context = BasicMacroExpansionContext(lexicalContext: [])

        let isValid = validator.validate(testCase.requirement, in: context)

        let diagnostic = try #require(context.diagnostics.first)
        #expect(!isValid)
        #expect(context.diagnostics.count == 1)
        #expect(diagnostic.diagnosticID == MessageID(domain: "ObserverMacro", id: testCase.id))
        #expect(diagnostic.message == testCase.message)
        #expect(diagnostic.fixIts.map { $0.message.message } == testCase.fixItMessages)
    }

    @Test("Non-class initialization emits the class-only diagnostic")
    func nonClassInitializationDiagnosesClassOnlyContract() throws {
        let declaration = try parseStruct("struct Monitor {}")
        let context = BasicMacroExpansionContext(lexicalContext: [])

        let validator = MacroAttachedClassValidator(
            validating: declaration,
            requirements: observerRequirements,
            in: context
        )

        let diagnostic = try #require(context.diagnostics.first)
        #expect(validator == nil)
        #expect(context.diagnostics.count == 1)
        #expect(diagnostic.diagnosticID == MessageID(domain: "ObserverMacro", id: "class-only"))
        #expect(
            diagnostic.message
                == "WHAT: @Observer can only be applied to a final class. WHY: Lifecycle state requires stable identity. HOW: Apply @Observer to a declaration like '@MainActor final class Monitor { let player: AVPlayer }'."
        )
        #expect(diagnostic.fixIts.isEmpty)
    }

    @Test("Batch validation diagnoses every requested failure")
    func batchValidationDiagnosesEveryFailure() throws {
        let validator = MacroAttachedClassValidator(
            classDeclaration: try parseClass(
                """
                class Monitor {
                    var player: AVPlayer
                    init(player: AVPlayer) { self.player = player }
                }
                """
            ),
            requirements: observerRequirements
        )
        let context = BasicMacroExpansionContext(lexicalContext: [])

        let isValid = validator.validate(
            [
                .finalClass,
                .mainActorIsolation,
                .storedLetProperty,
                .initializerAvailability,
            ],
            in: context
        )

        #expect(!isValid)
        #expect(
            context.diagnostics.map(\.diagnosticID)
                == [
                    MessageID(domain: "ObserverMacro", id: "class-only"),
                    MessageID(domain: "ObserverMacro", id: "mainactor-required"),
                    MessageID(domain: "ObserverMacro", id: "player-required"),
                    MessageID(domain: "ObserverMacro", id: "init-conflict"),
                ]
        )
    }

    @Test("Requirements configuration controls wording, property matching, domain, and IDs")
    func requirementsConfigurationIsNotHardCoded() throws {
        let matchingValidator = MacroAttachedClassValidator(
            classDeclaration: try parseClass(
                """
                @MainActor
                final class Tracker {
                    let session: Module.Session
                }
                """
            ),
            requirements: trackerRequirements
        )
        let missingPropertyValidator = MacroAttachedClassValidator(
            classDeclaration: try parseClass("@MainActor final class Tracker {}"),
            requirements: trackerRequirements
        )
        let context = BasicMacroExpansionContext(lexicalContext: [])

        let isValid = missingPropertyValidator.validate(.storedLetProperty, in: context)

        let diagnostic = try #require(context.diagnostics.first)
        #expect(
            matchingValidator.satisfies([
                .finalClass,
                .mainActorIsolation,
                .storedLetProperty,
                .initializerAvailability,
            ])
        )
        #expect(!isValid)
        #expect(diagnostic.diagnosticID == MessageID(domain: "TrackerMacro", id: "session-missing"))
        #expect(
            diagnostic.message
                == "WHAT: @Tracker requires a stored instance property 'let session: Session'. WHY: Tracking reads the session. HOW: Add 'let session: Session'."
        )
    }
}

struct MissingRequirement: Sendable {
    let source: String
    let requirement: MacroAttachedClassRequirement
    let id: String
    let message: String
    let fixItMessages: [String]
}

private let observerRequirements = MacroAttachedClassRequirements(
    attributeName: "@Observer",
    exampleClassName: "Monitor",
    lifecycleOwnershipReason: "Lifecycle state requires stable identity.",
    mainActorReason: "Callbacks mutate actor-owned state.",
    storedPropertyName: "player",
    storedPropertyTypeName: "AVPlayer",
    storedPropertyReason: "Observation reads the player.",
    initializerReason: "The macro owns initialization.",
    diagnosticDomain: "ObserverMacro",
    diagnosticIDs: .init(
        classOnly: "class-only",
        mainActorRequired: "mainactor-required",
        storedPropertyRequired: "player-required",
        initializerConflict: "init-conflict"
    )
)

private let trackerRequirements = MacroAttachedClassRequirements(
    attributeName: "@Tracker",
    exampleClassName: "Tracker",
    lifecycleOwnershipReason: "Tracking requires stable identity.",
    mainActorReason: "Tracking mutates actor-owned state.",
    storedPropertyName: "session",
    storedPropertyTypeName: "Session",
    storedPropertyReason: "Tracking reads the session.",
    initializerReason: "The tracker owns initialization.",
    diagnosticDomain: "TrackerMacro",
    diagnosticIDs: .init(
        classOnly: "tracker-class-only",
        mainActorRequired: "tracker-mainactor",
        storedPropertyRequired: "session-missing",
        initializerConflict: "tracker-init-conflict"
    )
)

private func parseClass(_ source: String) throws -> ClassDeclSyntax {
    let sourceFile = Parser.parse(source: source)
    return try #require(
        sourceFile.statements.compactMap { $0.item.as(ClassDeclSyntax.self) }.first
    )
}

private func parseStruct(_ source: String) throws -> StructDeclSyntax {
    let sourceFile = Parser.parse(source: source)
    return try #require(
        sourceFile.statements.compactMap { $0.item.as(StructDeclSyntax.self) }.first
    )
}
