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
                "@RequireFinal\npublic class Session {\n    open class Nested {}\n}\n",
                "@RequireFinal\npublic final class Session {\n    open class Nested {}\n}\n"
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
                == "WHAT: @RequireFinal requires a final class. WHY: Subclasses would bypass the type's invariants. HOW: Add the 'final' modifier to this class declaration."
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

    @Test("Open class emits conflict diagnostic without an invalid fix-it")
    func openClassEmitsConflictDiagnosticWithoutFixIt() throws {
        let result = expand("@RequireFinal\nopen class Session {}\n")
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
        #expect(
            diagnostic.message
                == "WHAT: @RequireFinal cannot be applied to an 'open' class. WHY: An 'open' class allows external subclassing, which conflicts with 'final'. HOW: Replace 'open' with 'public final', change any 'open' members to 'public', or remove @RequireFinal."
        )
        #expect(diagnostic.fixIts.isEmpty)
    }

    @Test(
        "Class with open members suppresses single-modifier fix-it",
        arguments: [
            """
            @RequireFinal
            public class Session {
                open func configure() {}
            }
            """,
            """
            @RequireFinal
            public class Session {
                #if DEBUG
                open var value: Int { 0 }
                #endif
            }
            """,
        ]
    )
    func classWithOpenMembersSuppressesSingleModifierFixIt(source: String) throws {
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
        #expect(
            diagnostic.message
                == "WHAT: @RequireFinal requires a final class, but this class declares 'open' members. WHY: Swift forbids 'open' members on a 'final' class. HOW: Change the 'open' members to 'public' and add the 'final' modifier to this class declaration."
        )
        #expect(diagnostic.fixIts.isEmpty)
    }

    @Test(
        "Class with nested subclass suppresses single-modifier fix-it",
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
                enum Namespace {
                    class Child: Session {}
                }
            }
            """,
        ]
    )
    func classWithNestedSubclassSuppressesSingleModifierFixIt(source: String) throws {
        let result = expand(source)
        #expect(result.diagnostics.count == 1)

        let diagnostic = try #require(result.diagnostics.first)
        #expect(
            diagnostic.diagnosticID
                == MessageID(
                    domain: RequireFinalMacro.diagnosticDomain,
                    id: RequireFinalDiagnosticID.nestedSubclass.rawValue
                )
        )
        #expect(diagnostic.diagMessage.severity == .error)
        #expect(
            diagnostic.message
                == "WHAT: @RequireFinal requires a final class, but this class has a nested subclass. WHY: Swift forbids subclassing a 'final' class. HOW: Remove inheritance from 'Session' on nested subclasses and add the 'final' modifier to this class declaration."
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
        contextGenerator: { _ in context },
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
