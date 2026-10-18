import MacroPluginUtilities
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@Suite("Macro source locations")
struct MacroSourceLocationTests {
    private static let filePath = "/Users/test/Sources/Model.swift"

    @Test("The directive names the node's file and line")
    func namesFileAndLine() throws {
        let (declaration, context) = try located("struct First {}\n\n/// Docs\nstruct Second {}")

        #expect(
            sourceLocationDirective(at: declaration, in: context)
                == #"#sourceLocation(file: "/Users/test/Sources/Model.swift", line: 4)"#
        )
    }

    @Test("The line offset shifts the attributed line")
    func appliesLineOffset() throws {
        let (declaration, context) = try located("struct First {}\nstruct Second {}")

        #expect(
            sourceLocationDirective(at: declaration, lineOffset: -1, in: context)
                == #"#sourceLocation(file: "/Users/test/Sources/Model.swift", line: 1)"#
        )
    }

    @Test("A node spanning lines is attributed to the line it starts on")
    func multilineNodeStartsTheRange() throws {
        let (declaration, context) = try located("struct First {}\n\n// Note\nstruct Second {\n    var value = 1\n}")

        #expect(
            sourceLocationDirective(at: declaration, in: context)
                == #"#sourceLocation(file: "/Users/test/Sources/Model.swift", line: 4)"#
        )
    }

    @Test("An offset below the first line has no directive")
    func offsetBelowFirstLineHasNoDirective() throws {
        let (declaration, context) = try located("struct Only {}")

        #expect(sourceLocationDirective(at: declaration, lineOffset: -1, in: context) == nil)
    }

    @Test("A path a string literal must escape has no directive", arguments: [
        #"/Users/test/Sources/Quote"d.swift"#,
        #"C:\Users\test\Model.swift"#,
        "/Users/test/Sources/Tab\tModel.swift",
        "/Users/test/Sources/Line\u{2028}Model.swift",
    ])
    func unrepresentablePathHasNoDirective(path: String) throws {
        let (declaration, context) = try located("struct Only {}", filePath: path)

        #expect(sourceLocationDirective(at: declaration, in: context) == nil)
    }

    @Test("A node outside the context's source files has no directive")
    func unknownNodeHasNoDirective() throws {
        let (_, context) = try located("struct First {}\nstruct Second {}")
        let detached = Parser.parse(source: "struct Elsewhere {}").statements

        #expect(sourceLocationDirective(at: detached, in: context) == nil)
    }

    /// The last declaration of `source`, and a context that knows the file at `filePath`.
    private func located(
        _ source: String,
        filePath: String = Self.filePath
    ) throws -> (DeclSyntax, BasicMacroExpansionContext) {
        let file = Parser.parse(source: source)
        let declaration = try #require(file.statements.last?.item.as(DeclSyntax.self))
        let context = BasicMacroExpansionContext(
            sourceFiles: [file: .init(moduleName: "Tests", fullFilePath: filePath)]
        )
        return (declaration, context)
    }
}
