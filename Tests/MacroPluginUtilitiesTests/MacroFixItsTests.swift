import MacroPluginUtilities
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import Testing

@Suite("Macro fix-its")
struct MacroFixItsTests {
    @Test("Add-final returns one complete replacement and preserves leading trivia")
    func addFinalPreservesLeadingTrivia() throws {
        let classDecl = try parseClass(
            """
            // leading

                class `switch` {}
            """
        )

        let fixIt = makeAddFinalFixIt(
            for: classDecl,
            fixItMessage: MacroFixItMessage("Add final", domain: "Tests")
        )
        let replacement = try #require(firstReplacement(in: fixIt))
        let replacementClass = replacement.newNode
            .as(ClassDeclSyntax.self)

        #expect(fixIt.changes.count == 1)
        #expect(replacement.oldNode == Syntax(classDecl))
        #expect(
            replacementClass?.description
                == """
                // leading

                    final class `switch` {}
                """
        )
    }

    @Test("Add-final preserves existing modifier order and trivia")
    func addFinalPreservesExistingModifiers() throws {
        let classDecl = try parseClass("public /* keep */ class Target {}")

        let fixIt = makeAddFinalFixIt(
            for: classDecl,
            fixItMessage: MacroFixItMessage("Add final", domain: "Tests")
        )
        let replacement = try #require(firstReplacement(in: fixIt))
        let replacementClass = replacement.newNode
            .as(ClassDeclSyntax.self)

        #expect(fixIt.changes.count == 1)
        #expect(replacement.oldNode == Syntax(classDecl))
        #expect(replacementClass?.description == "public /* keep */ final class Target {}")
    }

    @Test("Add-main-actor returns one complete attribute-list replacement")
    func addMainActorCreatesAttributeList() throws {
        let classDecl = try parseClass("class Target {}")

        let fixIt = makeAddMainActorFixIt(
            for: classDecl,
            fixItMessage: MacroFixItMessage("Add MainActor", domain: "Tests")
        )
        let replacement = try #require(firstReplacement(in: fixIt))
        let replacementAttributes = replacement.newNode
            .as(AttributeListSyntax.self)

        #expect(fixIt.changes.count == 1)
        #expect(replacement.oldNode == Syntax(classDecl.attributes))
        #expect(replacementAttributes?.description == "@MainActor\n")
    }

    @Test("Add-main-actor preserves qualified attributes, comments, and order")
    func addMainActorPreservesExistingAttributes() throws {
        let classDecl = try parseClass(
            """
            @Module.Existing // keep
            class `switch` {}
            """
        )

        let fixIt = makeAddMainActorFixIt(
            for: classDecl,
            fixItMessage: MacroFixItMessage("Add MainActor", domain: "Tests")
        )
        let replacement = try #require(firstReplacement(in: fixIt))
        let replacementAttributes = replacement.newNode
            .as(AttributeListSyntax.self)

        #expect(fixIt.changes.count == 1)
        #expect(replacement.oldNode == Syntax(classDecl.attributes))
        #expect(
            replacementAttributes?.description
                == """
                @MainActor
                @Module.Existing // keep
                """
        )
    }
}

private func parseClass(_ source: String) throws -> ClassDeclSyntax {
    try #require(
        Parser.parse(source: source)
            .statements.first?
            .item.as(DeclSyntax.self)?
            .as(ClassDeclSyntax.self)
    )
}

private func firstReplacement(in fixIt: FixIt) -> (oldNode: Syntax, newNode: Syntax)? {
    guard let change = fixIt.changes.first else {
        return nil
    }
    guard case .replace(let oldNode, let newNode) = change else {
        return nil
    }
    return (oldNode, newNode)
}
