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

    @Test("Add-main-actor returns one complete declaration replacement")
    func addMainActorReplacesDeclaration() throws {
        let classDecl = try parseClass("class Target {}")

        let fixIt = makeAddMainActorFixIt(
            for: classDecl,
            fixItMessage: MacroFixItMessage("Add MainActor", domain: "Tests")
        )
        let replacement = try #require(firstReplacement(in: fixIt))

        #expect(fixIt.changes.count == 1)
        #expect(replacement.oldNode == Syntax(classDecl))
        #expect(replacement.newNode.as(ClassDeclSyntax.self)?.attributes.description == "@MainActor\n")
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
            .as(ClassDeclSyntax.self)?.attributes

        #expect(fixIt.changes.count == 1)
        #expect(replacement.oldNode == Syntax(classDecl))
        #expect(
            replacementAttributes?.description
                == """
                @MainActor
                @Module.Existing // keep
                """
        )
    }

    @Test("Add-main-actor puts the attribute on its own line at the declaration's indentation")
    func addMainActorKeepsItsOwnLine() throws {
        let cases: [(source: String, fixed: String)] = [
            (
                "enum Outer {\n    @Existing\n    class Target {}\n}",
                "enum Outer {\n    @MainActor\n    @Existing\n    class Target {}\n}"
            ),
            (
                "enum Outer {\n    final class Target {}\n}",
                "enum Outer {\n    @MainActor\n    final class Target {}\n}"
            ),
            (
                "import Module\n\nclass Target {}",
                "import Module\n\n@MainActor\nclass Target {}"
            ),
            (
                "class Target {}",
                "@MainActor\nclass Target {}"
            ),
        ]
        for (source, fixed) in cases {
            let tree = Parser.parse(source: source)
            let classDecl = try #require(tree.firstClass)
            let fixIt = makeAddMainActorFixIt(
                for: classDecl,
                fixItMessage: MacroFixItMessage("Add MainActor", domain: "Tests")
            )
            #expect(applying(fixIt, to: tree) == fixed, "\(source)")
        }
    }

    @Test("Remove-initializer replaces only the binding and trims horizontal residue")
    func removeInitializerReplacesBindingAndTrimsResidue() throws {
        let classDecl = try parseClass("class Target { let value: Int = makeValue()   }")
        let property = try #require(
            inlineInitializedStoredProperty(named: "value", in: classDecl)
        )

        let fixIt = makeRemoveInitializerFixIt(
            from: property,
            propertyName: "value",
            domain: "Tests"
        )
        let replacement = try #require(firstReplacement(in: fixIt))

        #expect(fixIt.changes.count == 1)
        #expect(replacement.oldNode == Syntax(property.binding))
        #expect(replacement.newNode.as(PatternBindingSyntax.self)?.description == "value: Int")
        #expect(
            fixIt.message.fixItID
                == MessageID(domain: "Tests", id: "Remove 'value' initializer")
        )
    }

    @Test("Remove-initializer preserves comments after the initializer")
    func removeInitializerPreservesTrailingComment() throws {
        let classDecl = try parseClass(
            """
            class Target {
                let value: Int = makeValue() // keep
            }
            """
        )
        let property = try #require(
            inlineInitializedStoredProperty(named: "value", in: classDecl)
        )

        let fixIt = makeRemoveInitializerFixIt(
            from: property,
            propertyName: "value",
            domain: "Tests"
        )
        let replacement = try #require(firstReplacement(in: fixIt))

        #expect(
            replacement.newNode.as(PatternBindingSyntax.self)?.description
                == "value: Int // keep"
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

private extension SourceFileSyntax {
    var firstClass: ClassDeclSyntax? {
        final class Finder: SyntaxVisitor {
            var found: ClassDeclSyntax?
            override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
                if found == nil { found = node }
                return .skipChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(self)
        return finder.found
    }
}

/// Applies a fix-it's edits the way the compiler does: each change replaces its
/// source range, including trivia.
private func applying(_ fixIt: FixIt, to tree: SourceFileSyntax) -> String {
    var bytes = Array(tree.description.utf8)
    for edit in fixIt.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
        bytes.replaceSubrange(
            edit.range.lowerBound.utf8Offset..<edit.range.upperBound.utf8Offset,
            with: Array(edit.replacement.utf8)
        )
    }
    return String(decoding: bytes, as: UTF8.self)
}
