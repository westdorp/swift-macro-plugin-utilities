import MacroPluginUtilities
import SwiftParser
import SwiftSyntax
import Testing

@Suite("Type Matching")
struct TypeMatchingTests {
    @Test(
        "Accepts compiler-identical spellings of the expected type",
        arguments: [
            ("Error?", "Error?"),
            ("(any Error)?", "Error?"),
            ("(Error)?", "Error?"),
            ("any Error", "Error"),
            ("(any Swift.Error)?", "Error?"),
            ("Optional<Error>", "Error?"),
            ("Optional<any Error>", "Error?"),
            ("AVPlayer.TimeControlStatus", "AVPlayer.TimeControlStatus"),
        ]
    )
    func acceptsEquivalentSpellings(actual: String, expected: String) {
        #expect(typeMatches(parseType(actual), expectedTypeName: expected))
    }

    @Test(
        "Rejects types that are not the expected type",
        arguments: [
            ("some Error", "Error"),
            ("Bool", "Bool?"),
            ("(Int, Int)", "Int"),
            ("Int", "Float"),
            ("Optional<Int>", "Int"),
        ]
    )
    func rejectsDistinctTypes(actual: String, expected: String) {
        #expect(!typeMatches(parseType(actual), expectedTypeName: expected))
    }
}

private func parseType(_ source: String) -> TypeSyntax {
    var parser = Parser(source)
    return TypeSyntax.parse(from: &parser)
}
