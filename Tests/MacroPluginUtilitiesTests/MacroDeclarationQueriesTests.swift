import MacroPluginUtilities
import SwiftParser
import SwiftSyntax
import Testing

@Suite("Macro declaration queries")
struct MacroDeclarationQueriesTests {
    @Test(
        "Modifier matching is exact",
        arguments: [
            ("final class Target {}", "final", true),
            ("static var value: Int", "static", true),
            ("class var value: Int { 0 }", "class", true),
            ("nonisolated class Target {}", "isolated", false),
            ("public final class Target {}", "publicFinal", false),
        ]
    )
    func modifierMatchingIsExact(source: String, name: String, expected: Bool) throws {
        let modifiers = try #require(parseModifiers(source))

        #expect(hasModifier(named: name, in: modifiers) == expected)
    }

    @Test(
        "Attribute matching accepts qualification and rejects suffix collisions",
        arguments: [
            ("@MainActor class Target {}", "MainActor", true),
            ("@Concurrency.MainActor class Target {}", "MainActor", true),
            ("@NotMainActor class Target {}", "MainActor", false),
            ("@MainActorish class Target {}", "MainActor", false),
        ]
    )
    func attributeMatchingUsesCompleteBasenames(
        source: String,
        name: String,
        expected: Bool
    ) throws {
        let attributes = try #require(parseAttributes(source))
        let attribute = try #require(
            attributes.compactMap { $0.as(AttributeSyntax.self) }.first
        )

        #expect(hasAttribute(named: name, in: attributes) == expected)
        #expect(attributeNameMatches(attribute, expected: name) == expected)
    }

    @Test(
        "Type matching accepts equivalent spellings",
        arguments: [
            ("Error?", "Error?"),
            ("(any Error)?", "Error?"),
            ("(Error)?", "Error?"),
            ("any Error", "Error"),
            ("(any Swift.Error)?", "Error?"),
            ("Optional<Error>", "Error?"),
            ("Optional<any Error>", "Error?"),
            ("AVPlayer.TimeControlStatus", "AVPlayer.TimeControlStatus"),
            ("External.Error", "Error"),
            ("Dictionary < String, Int >", "Dictionary<String,Int>"),
        ]
    )
    func typeMatchingAcceptsEquivalentSpellings(actual: String, expected: String) {
        #expect(typeMatches(parseType(actual), expectedTypeName: expected))
    }

    @Test(
        "Type matching rejects distinct and deceptive spellings",
        arguments: [
            ("some Error", "Error"),
            ("Bool", "Bool?"),
            ("(Int, Int)", "Int"),
            ("Int", "Float"),
            ("Optional<Int>", "Int"),
            ("External.ErrorBox", "Error"),
            ("NotError", "Error"),
            ("Errors.ErrorLike", "Error"),
        ]
    )
    func typeMatchingRejectsDistinctSpellings(actual: String, expected: String) {
        #expect(!typeMatches(parseType(actual), expectedTypeName: expected))
    }

    @Test("Existential markers normalize while opaque markers remain distinct")
    func existentialAndOpaqueTypesRemainAsymmetric() {
        #expect(typeMatches(parseType("any Error"), expectedTypeName: "Error"))
        #expect(!typeMatches(parseType("some Error"), expectedTypeName: "Error"))
    }

    @Test(
        "Instance-variable matching excludes type properties",
        arguments: [
            ("var value: Int", true),
            ("private let value: Int", true),
            ("static var value: Int", false),
            ("private static let value: Int", false),
            ("override class var value: Int { 0 }", false),
        ]
    )
    func instanceVariableMatchingExcludesTypeProperties(source: String, expected: Bool) throws {
        let variable = try #require(parseDeclaration(source)?.as(VariableDeclSyntax.self))

        #expect(isInstanceVariable(variable) == expected)
    }
}

private func parseModifiers(_ source: String) -> DeclModifierListSyntax? {
    guard let declaration = parseDeclaration(source) else {
        return nil
    }
    if let classDecl = declaration.as(ClassDeclSyntax.self) {
        return classDecl.modifiers
    }
    return declaration.as(VariableDeclSyntax.self)?.modifiers
}

private func parseAttributes(_ source: String) -> AttributeListSyntax? {
    parseDeclaration(source)?.as(ClassDeclSyntax.self)?.attributes
}

private func parseDeclaration(_ source: String) -> DeclSyntax? {
    Parser.parse(source: source).statements.first?.item.as(DeclSyntax.self)
}

private func parseType(_ source: String) -> TypeSyntax {
    var parser = Parser(source)
    return TypeSyntax.parse(from: &parser)
}
