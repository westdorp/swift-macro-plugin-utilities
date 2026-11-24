import RequireFinal
import RequireFinalMacros
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import Testing

@RequireFinal
private final class CompiledSession {
    let label: String

    init(label: String) {
        self.label = label
    }
}

@Suite("RequireFinal macro")
struct RequireFinalMacroTests {
    @Test("Compiled final class passes macro validation")
    func compiledFinalClassPassesMacroValidation() {
        let session = CompiledSession(label: "verified")
        #expect(session.label == "verified")
    }

    @Test(
        "Final class expands without diagnostics",
        arguments: [
            "@RequireFinal\nfinal class Session {}\n",
            "@RequireFinal\npublic final class Session {}\n",
            "@RequireFinal\npublic final class Session {\n    open class Nested {}\n}\n",
        ]
    )
    func finalClassExpandsWithoutDiagnostics(source: String) {
        let result = expand(source)
        #expect(result.diagnostics.isEmpty)
    }

    @Test(
        "Non-final class emits structured diagnostic and deterministic fix-it",
        arguments: [
            (
                "@RequireFinal\nclass Session {}\n",
                "@RequireFinal\nfinal class Session {}\n"
            ),
            (
                "@RequireFinal\npublic /* keep */ class Session {}\n",
                "@RequireFinal\npublic /* keep */ final class Session {}\n"
            ),
            (
                "@RequireFinal\npublic\nclass Session {}\n",
                "@RequireFinal\npublic\nfinal class Session {}\n"
            ),
            (
                "@RequireFinal\npublic // keep\n    class Session {}\n",
                "@RequireFinal\npublic // keep\n    final class Session {}\n"
            ),
            (
                "// café — naïve\n@RequireFinal\nclass Session {}\n",
                "// café — naïve\n@RequireFinal\nfinal class Session {}\n"
            ),
            (
                "enum Scope {\n    @RequireFinal\n    class Session {}\n}\n",
                "enum Scope {\n    @RequireFinal\n    final class Session {}\n}\n"
            ),
            (
                "@RequireFinal\npublic class Session {\n    struct Nested {}\n}\n",
                "@RequireFinal\npublic final class Session {\n    struct Nested {}\n}\n"
            ),
        ]
    )
    func nonFinalClassEmitsStructuredDiagnosticAndFixIt(
        source: String,
        expectedFixedSource: String
    ) throws {
        let result = expand(source)
        #expect(result.diagnostics.count == 1)

        let diagnostic = try #require(result.diagnostics.first)
        #expect(
            diagnostic.diagnosticID
                == MessageID(
                    domain: RequireFinalMacro.diagnosticDomain,
                    id: RequireFinalDiagnosticID.missingFinal.rawValue
                )
        )
        #expect(diagnostic.diagMessage.severity == .error)
        #expect(
            diagnostic.message
                == "WHAT: @RequireFinal requires a final class. WHY: Subclasses would bypass the type's invariants. HOW: Confirm no external declaration subclasses this type, then add the 'final' modifier to this class declaration."
        )
        #expect(diagnostic.fixIts.count == 1)

        let fixIt = try #require(diagnostic.fixIts.first)
        #expect(fixIt.message.message == "Add 'final' modifier")
        #expect(
            fixIt.message.fixItID
                == MessageID(
                    domain: RequireFinalMacro.diagnosticDomain,
                    id: "Add 'final' modifier"
                )
        )

        let fixedSource = try #require(applying(fixIt, in: result))
        #expect(Array(fixedSource.utf8) == Array(expectedFixedSource.utf8))

        let reexpanded = expand(fixedSource)
        #expect(reexpanded.diagnostics.isEmpty)
    }

    @Test(
        "Open class emits conflict diagnostic without an invalid fix-it",
        arguments: [
            (
                "@RequireFinal\nopen class Session {}\n",
                "WHAT: @RequireFinal cannot be applied to an 'open' class. WHY: An 'open' class allows external subclassing, which conflicts with 'final'. HOW: Replace 'open' with 'public final', change any 'open' members to 'public', update or remove any subclasses, or remove @RequireFinal."
            ),
            (
                "@RequireFinal\nopen class Session {\n    final class Child: Session {}\n}\n",
                "WHAT: @RequireFinal cannot be applied to an 'open' class. WHY: An 'open' class allows external subclassing, which conflicts with 'final'. HOW: Replace 'open' with 'public final', change any 'open' members to 'public', update or remove any subclasses, or remove @RequireFinal."
            ),
            (
                "@RequireFinal\nopen final class Session {}\n",
                "WHAT: @RequireFinal cannot be applied to an 'open' class. WHY: An 'open' class allows external subclassing, which conflicts with 'final'. HOW: Replace 'open' with 'public', change any 'open' members to 'public', update or remove any subclasses, or remove both 'final' and @RequireFinal."
            ),
        ]
    )
    func openClassEmitsConflictDiagnosticWithoutFixIt(
        source: String,
        expectedMessage: String
    ) throws {
        let result = expand(source)
        #expect(result.diagnostics.count == 1)

        let diagnostic = try #require(result.diagnostics.first)
        #expect(
            diagnostic.diagnosticID
                == MessageID(
                    domain: RequireFinalMacro.diagnosticDomain,
                    id: RequireFinalDiagnosticID.openClass.rawValue
                )
        )
        #expect(diagnostic.diagMessage.severity == .error)
        #expect(diagnostic.message == expectedMessage)
        #expect(diagnostic.fixIts.isEmpty)
    }

    @Test(
        "Class with open members suppresses single-modifier fix-it",
        arguments: [
            (
                """
                @RequireFinal
                public class Session {
                    open func configure() {}
                }
                """,
                "WHAT: @RequireFinal requires a final class, but this class contains 'open' member declarations. WHY: Swift forbids 'open' members on a 'final' class. HOW: Change any 'open' members to 'public' before adding 'final'."
            ),
            (
                """
                @RequireFinal
                public class Session {
                    #if DEBUG
                    open var value: Int { 0 }
                    #endif
                }
                """,
                "WHAT: @RequireFinal requires a final class, but this class contains 'open' member declarations. WHY: Swift forbids 'open' members on a 'final' class. HOW: Change any 'open' members to 'public' before adding 'final'."
            ),
            (
                """
                @RequireFinal
                public class Session {
                    open func configure() {}
                    class Child: Session {}
                }
                """,
                "WHAT: @RequireFinal requires a final class, but this class contains 'open' member declarations. WHY: Swift forbids 'open' members on a 'final' class. HOW: Change any 'open' members to 'public', review nested or local classes and update any subclassing, and add the 'final' modifier manually."
            ),
            (
                """
                @RequireFinal
                public final class Session {
                    open func configure() {}
                }
                """,
                "WHAT: @RequireFinal cannot accept a 'final' class that contains 'open' member declarations. WHY: Swift forbids 'open' members on a 'final' class. HOW: Change any 'open' members to 'public' so they are valid on a 'final' class."
            ),
        ]
    )
    func classWithOpenMembersSuppressesSingleModifierFixIt(
        source: String,
        expectedMessage: String
    ) throws {
        let result = expand(source)
        #expect(result.diagnostics.count == 1)

        let diagnostic = try #require(result.diagnostics.first)
        #expect(
            diagnostic.diagnosticID
                == MessageID(
                    domain: RequireFinalMacro.diagnosticDomain,
                    id: RequireFinalDiagnosticID.openMembers.rawValue
                )
        )
        #expect(diagnostic.diagMessage.severity == .error)
        #expect(diagnostic.message == expectedMessage)
        #expect(diagnostic.fixIts.isEmpty)
    }

    @Test(
        "Class with nested or local class declarations suppresses automatic fix-it",
        arguments: [
            """
            @RequireFinal
            class Session {
                class Child: Session {}
            }
            """,
            """
            @RequireFinal
            class Session {
                typealias Base = Session
                class Child: Base {}
            }
            """,
            """
            @RequireFinal
            class Session {
                func make() {
                    class Local: Session {}
                    _ = Local()
                }
            }
            """,
            """
            @RequireFinal
            public class Session {
                open class Nested {}
            }
            """,
        ]
    )
    func classWithNestedClassesSuppressesAutomaticFixIt(source: String) throws {
        let result = expand(source)
        #expect(result.diagnostics.count == 1)

        let diagnostic = try #require(result.diagnostics.first)
        #expect(
            diagnostic.diagnosticID
                == MessageID(
                    domain: RequireFinalMacro.diagnosticDomain,
                    id: RequireFinalDiagnosticID.nestedClasses.rawValue
                )
        )
        #expect(diagnostic.diagMessage.severity == .error)
        #expect(
            diagnostic.message
                == "WHAT: @RequireFinal requires a final class, and omits the automatic fix-it when the class contains nested or local class declarations. WHY: Nested or local classes may subclass this class, which Swift forbids once 'final' is added. HOW: Review nested or local classes, update any subclassing, and add the 'final' modifier manually."
        )
        #expect(diagnostic.fixIts.isEmpty)
    }

    @Test(
        "Non-class declaration emits class-only diagnostic without a fix-it",
        arguments: [
            "@RequireFinal\nstruct Session {}\n",
            "@RequireFinal\nenum Session {}\n",
            "@RequireFinal\nactor Session {}\n",
            "class Session {}\n@RequireFinal\nextension Session {}\n",
        ]
    )
    func nonClassDeclarationEmitsClassOnlyDiagnostic(source: String) throws {
        let result = expand(source)
        #expect(result.diagnostics.count == 1)

        let diagnostic = try #require(result.diagnostics.first)
        #expect(
            diagnostic.diagnosticID
                == MessageID(
                    domain: RequireFinalMacro.diagnosticDomain,
                    id: RequireFinalDiagnosticID.nonClassDeclaration.rawValue
                )
        )
        #expect(diagnostic.diagMessage.severity == .error)
        #expect(
            diagnostic.message
                == "WHAT: @RequireFinal can only be applied to a class. WHY: Only classes can be subclassed and require a 'final' modifier. HOW: Remove @RequireFinal from this declaration or attach it to a class."
        )
        #expect(diagnostic.fixIts.isEmpty)
    }

    @Test("Fix-it applier rejects an edit anchored to an unregistered syntax tree")
    func fixItApplierRejectsUnmappedAnchor() throws {
        let result = expand("@RequireFinal\nclass Session {}\n")
        let unmappedTree = Parser.parse(source: "@RequireFinal\nclass Session {}\n")
        let unmappedClass = try #require(
            unmappedTree.statements.first?.item.as(ClassDeclSyntax.self)
        )
        let unmappedFixIt = FixIt(
            message: UnmappedFixItMessage(),
            changes: [
                .replace(
                    oldNode: Syntax(unmappedClass),
                    newNode: Syntax(unmappedClass)
                )
            ]
        )

        #expect(applying(unmappedFixIt, in: result) == nil)
    }
}

private struct UnmappedFixItMessage: FixItMessage {
    let message = "Unmapped"
    let fixItID = MessageID(domain: "RequireFinalMacroTests", id: "unmapped")
}

private struct ExpansionResult {
    let sourceFile: SourceFileSyntax
    let context: BasicMacroExpansionContext
    let diagnostics: [Diagnostic]
}

private func expand(_ source: String) -> ExpansionResult {
    let sourceFile = Parser.parse(source: source)
    let context = BasicMacroExpansionContext(
        sourceFiles: [
            sourceFile: .init(moduleName: "ExampleModule", fullFilePath: "Example.swift")
        ]
    )
    _ = sourceFile.expand(
        macros: ["RequireFinal": RequireFinalMacro.self],
        contextGenerator: { syntax in
            BasicMacroExpansionContext(
                sharingWith: context,
                lexicalContext: syntax.allMacroLexicalContexts()
            )
        },
        indentationWidth: .spaces(4)
    )
    return ExpansionResult(
        sourceFile: sourceFile,
        context: context,
        diagnostics: context.diagnostics
    )
}

private func applying(_ fixIt: FixIt, in result: ExpansionResult) -> String? {
    var bytes = Array(result.sourceFile.description.utf8)
    var edits: [(range: Range<Int>, replacement: String)] = []

    for change in fixIt.changes {
        guard case .replace(let oldNode, let newNode) = change else {
            return nil
        }
        guard result.context.location(
            of: oldNode,
            at: .beforeLeadingTrivia,
            filePathMode: .filePath
        ) != nil else {
            return nil
        }
        let start = result.context.location(
            for: oldNode.position,
            anchoredAt: oldNode,
            fileName: "Example.swift"
        )
        let end = result.context.location(
            for: oldNode.endPosition,
            anchoredAt: oldNode,
            fileName: "Example.swift"
        )
        guard start.offset >= 0, start.offset <= end.offset, end.offset <= bytes.count else {
            return nil
        }
        edits.append((range: start.offset..<end.offset, replacement: newNode.description))
    }

    var previousLowerBound = bytes.count
    for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
        guard edit.range.upperBound <= previousLowerBound else {
            return nil
        }
        bytes.replaceSubrange(edit.range, with: Array(edit.replacement.utf8))
        previousLowerBound = edit.range.lowerBound
    }
    return String(decoding: bytes, as: UTF8.self)
}
