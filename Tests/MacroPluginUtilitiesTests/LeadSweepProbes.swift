import MacroPluginUtilities
import SwiftParser
import SwiftSyntax
import Testing

@Suite("Lead sweep pins")
struct LeadSweepProbes {
    @Test("Conditional Sendable extension is discovered syntactically")
    func conditionalConformance() {
        let file = Parser.parse(source: """
        struct Box<T> { }
        extension Box: Sendable where T: Sendable { }
        """)
        let box = file.statements.first!.item.as(StructDeclSyntax.self)!
        #expect(hasSendableConformance(in: box))
    }

    @Test("Extensions inside #if blocks are not discovered")
    func ifConfigWrappedExtensionIsOutsideTraversal() {
        let file = Parser.parse(source: """
        struct Gated { }
        #if os(macOS)
        extension Gated: Sendable { }
        #endif
        """)
        let gated = file.statements.first!.item.as(StructDeclSyntax.self)!
        #expect(!hasSendableConformance(in: gated))
    }

    @Test("Deeply nested optional spellings normalize exactly")
    func deepOptionalSpellings() {
        func parseType(_ source: String) -> TypeSyntax {
            var parser = Parser(source)
            return TypeSyntax.parse(from: &parser)
        }
        #expect(typeMatches(parseType("Optional<Optional<Int>>"), expectedTypeName: "Int??"))
        #expect(typeMatches(parseType("(((Int)))"), expectedTypeName: "Int"))
        #expect(!typeMatches(parseType("Int???"), expectedTypeName: "Int??"))
    }

    @Test("Add-final rewrite preserves comment, attribute, and modifier order")
    func fixItTriviaPileup() {
        let source = """
        // owner comment
        @MainActor
        public class `class` { }
        """
        let classDecl = Parser.parse(source: source).statements.first!.item.as(ClassDeclSyntax.self)!
        let fixIt = makeAddFinalFixIt(
            for: classDecl,
            fixItMessage: .init("Add final", domain: "LeadSweepProbes")
        )
        let newText = fixIt.changes.compactMap { change -> String? in
            if case .replace(_, let newNode) = change { return newNode.description }
            return nil
        }.joined()
        #expect(newText.contains("// owner comment"))
        #expect(newText.contains("@MainActor"))
        #expect(newText.contains("public final class `class`"))
    }
}
